import { describe, expect, it } from "vitest";
import { musoProfileUrl } from "../src/ticket-format.js";

describe("musoProfileUrl", () => {
  it("links the public muso.ai profile page, not the legacy credits.muso.ai host", () => {
    expect(musoProfileUrl("abc123de")).toBe("https://muso.ai/profile/abc123de");
  });
});
