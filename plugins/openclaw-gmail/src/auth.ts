import { OAuth2Client, JWT } from "google-auth-library";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import http from "node:http";
import { execFile } from "node:child_process";
import type { OpenClawConfig } from "openclaw/plugin-sdk";

export interface OAuthCredentials {
  clientId: string;
  clientSecret: string;
  refreshToken: string;
}

// Service account key file path. Provisioned out-of-band (Vault → /opt/hydra/secrets/).
// NEVER committed to repo. See H-DevOps/scripts/node8-provision/README.md.
const SA_KEY_PATH = "/opt/hydra/secrets/google-sa-hydra.json";

/**
 * Try to create an authenticated client using the Google service account
 * with domain-wide delegation. This never expires.
 * Falls back to null if key file missing.
 */
export function createServiceAccountClient(email: string): OAuth2Client | null {
  try {
    if (!fs.existsSync(SA_KEY_PATH)) {
      return null;
    }
    const keyData = JSON.parse(fs.readFileSync(SA_KEY_PATH, "utf-8"));
    const jwtClient = new JWT({
      email: keyData.client_email,
      key: keyData.private_key,
      scopes: ["https://mail.google.com/"],
      subject: email,
    });
    return jwtClient as unknown as OAuth2Client;
  } catch (err) {
    console.error("[openclaw-gmail] Service account auth failed for", email, ":", String(err));
    return null;
  }
}

/**
 * Read gog CLI credentials.json to reuse its OAuth client_id/client_secret.
 */
export function readGogCredentials(): { clientId: string; clientSecret: string } | null {
  const credPath = path.join(os.homedir(), ".config", "gogcli", "credentials.json");
  try {
    const raw = fs.readFileSync(credPath, "utf-8");
    const data = JSON.parse(raw);
    if (typeof data.client_id === "string" && typeof data.client_secret === "string") {
      return { clientId: data.client_id, clientSecret: data.client_secret };
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Resolve OAuth credentials from config, falling back to gog credentials.json.
 */
export function resolveOAuthCredentials(
  accountEmail: string,
  cfg: OpenClawConfig,
): OAuthCredentials | null {
  const accounts = (cfg.channels as any)?.["openclaw-gmail"]?.accounts;
  const account = accounts?.[accountEmail] ?? Object.values(accounts ?? {}).find(
    (a: any) => a.email === accountEmail,
  );

  const oauth = (account as any)?.oauth;
  if (oauth?.clientId && oauth?.clientSecret && oauth?.refreshToken) {
    return {
      clientId: oauth.clientId,
      clientSecret: oauth.clientSecret,
      refreshToken: oauth.refreshToken,
    };
  }

  if (oauth?.refreshToken) {
    const gogCreds = readGogCredentials();
    if (gogCreds) {
      return {
        clientId: oauth.clientId || gogCreds.clientId,
        clientSecret: oauth.clientSecret || gogCreds.clientSecret,
        refreshToken: oauth.refreshToken,
      };
    }
  }

  return null;
}

/**
 * Resolve just the client_id/client_secret pair.
 */
export function resolveClientCredentials(
  accountEmail: string,
  cfg: OpenClawConfig,
): { clientId: string; clientSecret: string } | null {
  const accounts = (cfg.channels as any)?.["openclaw-gmail"]?.accounts;
  const account = accounts?.[accountEmail] ?? Object.values(accounts ?? {}).find(
    (a: any) => a.email === accountEmail,
  );

  const oauth = (account as any)?.oauth;
  if (oauth?.clientId && oauth?.clientSecret) {
    return { clientId: oauth.clientId, clientSecret: oauth.clientSecret };
  }

  return readGogCredentials();
}

/**
 * Create an authenticated OAuth2Client.
 * Prefers service account (never expires) over refresh token.
 */
export function createOAuth2Client(creds: OAuthCredentials, email?: string): OAuth2Client {
  if (email) {
    const saClient = createServiceAccountClient(email);
    if (saClient) {
      console.error("[openclaw-gmail] Using service account for", email);
      return saClient;
    }
  }

  console.error("[openclaw-gmail] Using OAuth refresh token for", email || "unknown");
  const client = new OAuth2Client(creds.clientId, creds.clientSecret);
  client.setCredentials({ refresh_token: creds.refreshToken });
  return client;
}

function openBrowser(url: string): void {
  const cmd = process.platform === "darwin" ? "open" : "xdg-open";
  execFile(cmd, [url], (err) => {
    if (err) {
      // URL is already printed to console
    }
  });
}

export async function runOAuthFlow(
  clientId: string,
  clientSecret: string,
  opts?: { port?: number },
): Promise<string> {
  const port = opts?.port ?? 0;

  return new Promise<string>((resolve, reject) => {
    const server = http.createServer();

    const timeout = setTimeout(() => {
      server.close();
      reject(new Error("OAuth flow timed out after 5 minutes"));
    }, 5 * 60 * 1000);

    server.listen(port, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        clearTimeout(timeout);
        server.close();
        reject(new Error("Failed to start local OAuth server"));
        return;
      }

      const redirectUri = `http://127.0.0.1:${addr.port}/callback`;
      const oauth2Client = new OAuth2Client(clientId, clientSecret, redirectUri);

      const authUrl = oauth2Client.generateAuthUrl({
        access_type: "offline",
        scope: ["https://mail.google.com/"],
        prompt: "consent",
      });

      console.log(`\nOpen this URL in your browser to authorize:\n\n  ${authUrl}\n`);
      openBrowser(authUrl);

      server.on("request", async (req, res) => {
        if (!req.url?.startsWith("/callback")) {
          res.writeHead(404);
          res.end("Not found");
          return;
        }

        const url = new URL(req.url, `http://127.0.0.1:${addr.port}`);
        const code = url.searchParams.get("code");
        const error = url.searchParams.get("error");

        if (error) {
          res.writeHead(200, { "Content-Type": "text/html" });
          res.end("<h1>Authorization denied</h1><p>You can close this tab.</p>");
          clearTimeout(timeout);
          server.close();
          reject(new Error(`OAuth authorization denied: ${error}`));
          return;
        }

        if (!code) {
          res.writeHead(400, { "Content-Type": "text/html" });
          res.end("<h1>Missing authorization code</h1>");
          return;
        }

        try {
          const { tokens } = await oauth2Client.getToken(code);
          if (!tokens.refresh_token) {
            res.writeHead(200, { "Content-Type": "text/html" });
            res.end("<h1>Error</h1><p>No refresh token. Revoke access and retry.</p>");
            clearTimeout(timeout);
            server.close();
            reject(new Error("No refresh_token received."));
            return;
          }

          res.writeHead(200, { "Content-Type": "text/html" });
          res.end("<h1>Authorization successful!</h1><p>You can close this tab.</p>");
          clearTimeout(timeout);
          server.close();
          resolve(tokens.refresh_token);
        } catch (err) {
          res.writeHead(500, { "Content-Type": "text/html" });
          res.end("<h1>Token exchange failed</h1>");
          clearTimeout(timeout);
          server.close();
          reject(err);
        }
      });
    });

    server.on("error", (err) => {
      clearTimeout(timeout);
      reject(err);
    });
  });
}
