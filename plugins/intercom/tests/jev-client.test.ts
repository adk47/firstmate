import { describe, it, expect, vi } from "vitest";
import { callJev, DEFAULT_JEV_MODEL, DEFAULT_JEV_TIMEOUT_MS } from "../src/jev-client.js";
import carolineQuestions from "../src/caroline-questions.json";

const BASE_INPUT = {
  apiKey: "k",
  state: { message: "hi" },
  questions: { resolution_path: { type: "choice" } },
};

describe("callJev", () => {
  it("returns the answers/usage/model/latencyMs shape on success", async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        model: "jev-1.13.0",
        answers: { resolution_path: { type: "choice", choice: "caroline_tool" } },
        usage: { input_tokens: 10, output_tokens: 5 },
      }),
    })) as unknown as typeof fetch;

    const result = await callJev({ ...BASE_INPUT, fetchImpl });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected ok");
    expect(result.answers).toEqual({ resolution_path: { type: "choice", choice: "caroline_tool" } });
    expect(result.usage).toEqual({ input_tokens: 10, output_tokens: 5 });
    expect(result.model).toBe("jev-1.13.0");
    expect(typeof result.latencyMs).toBe("number");
  });

  it("POSTs the exact {model, state, questions} body to the decisions endpoint", async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ answers: {} }),
    })) as unknown as typeof fetch;

    await callJev({ ...BASE_INPUT, model: "typesafe/jev-1.13", fetchImpl });
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    const [url, init] = (fetchImpl as any).mock.calls[0];
    expect(url).toBe("https://openrouter.ai/api/alpha/decisions");
    expect(init.method).toBe("POST");
    expect(init.headers.Authorization).toBe("Bearer k");
    expect(JSON.parse(init.body)).toEqual({
      model: "typesafe/jev-1.13",
      state: BASE_INPUT.state,
      questions: BASE_INPUT.questions,
    });
  });

  it("defaults model to typesafe/jev-1.13 when unset", async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ answers: {} }),
    })) as unknown as typeof fetch;
    await callJev({ ...BASE_INPUT, fetchImpl });
    const [, init] = (fetchImpl as any).mock.calls[0];
    expect(JSON.parse(init.body).model).toBe(DEFAULT_JEV_MODEL);
    expect(DEFAULT_JEV_MODEL).toBe("typesafe/jev-1.13");
  });

  it("returns null and warns reason=timeout when the request is aborted", async () => {
    const fetchImpl = vi.fn((_url: string, init: RequestInit) => {
      return new Promise((_resolve, reject) => {
        (init.signal as AbortSignal).addEventListener("abort", () => {
          const err = new Error("aborted");
          err.name = "AbortError";
          reject(err);
        });
      });
    }) as unknown as typeof fetch;
    const warned: string[] = [];

    const result = await callJev({ ...BASE_INPUT, timeoutMs: 5, fetchImpl, log: { warn: (m) => warned.push(m) } });
    expect(result).toEqual({ ok: false, reason: "timeout", httpStatus: null, latencyMs: expect.any(Number) });
    expect(warned).toEqual(["[intercom:jev] rc=fail reason=timeout"]);
  });

  it("returns null and warns reason=http_500 on a non-2xx response", async () => {
    const fetchImpl = vi.fn(async () => ({ ok: false, status: 500 })) as unknown as typeof fetch;
    const warned: string[] = [];

    const result = await callJev({ ...BASE_INPUT, fetchImpl, log: { warn: (m) => warned.push(m) } });
    expect(result).toEqual({ ok: false, reason: "http_500", httpStatus: 500, latencyMs: expect.any(Number) });
    expect(warned).toEqual(["[intercom:jev] rc=fail reason=http_500"]);
  });

  it("returns null and warns reason=shape when .answers is missing", async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ model: "jev-1.13.0" }),
    })) as unknown as typeof fetch;
    const warned: string[] = [];

    const result = await callJev({ ...BASE_INPUT, fetchImpl, log: { warn: (m) => warned.push(m) } });
    expect(result).toEqual({ ok: false, reason: "shape", httpStatus: 200, latencyMs: expect.any(Number) });
    expect(warned).toEqual(["[intercom:jev] rc=fail reason=shape"]);
  });

  it("returns null and warns reason=shape when .answers is not an object", async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ answers: "not-an-object" }),
    })) as unknown as typeof fetch;
    const warned: string[] = [];

    const result = await callJev({ ...BASE_INPUT, fetchImpl, log: { warn: (m) => warned.push(m) } });
    expect(result).toEqual({ ok: false, reason: "shape", httpStatus: 200, latencyMs: expect.any(Number) });
    expect(warned).toEqual(["[intercom:jev] rc=fail reason=shape"]);
  });

  it("returns null and warns reason=network on a fetch rejection", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    }) as unknown as typeof fetch;
    const warned: string[] = [];

    const result = await callJev({ ...BASE_INPUT, fetchImpl, log: { warn: (m) => warned.push(m) } });
    expect(result).toEqual({ ok: false, reason: "network", httpStatus: null, latencyMs: expect.any(Number) });
    expect(warned).toEqual(["[intercom:jev] rc=fail reason=network"]);
  });

  it("never throws even without a log passed", async () => {
    const fetchImpl = vi.fn(async () => ({ ok: false, status: 401 })) as unknown as typeof fetch;
    await expect(callJev({ ...BASE_INPUT, fetchImpl })).resolves.toEqual({
      ok: false,
      reason: "http_401",
      httpStatus: 401,
      latencyMs: expect.any(Number),
    });
  });

  it("applies the default timeout when none is passed", () => {
    expect(DEFAULT_JEV_TIMEOUT_MS).toBe(1500);
  });

  // QA finding 2 (2026-09-22 PR #999): a 200 response can carry a well-formed
  // top-level {answers:{...}} envelope while a NESTED field is malformed. The
  // endpoint is alpha, so this is a live risk — every malformed shape below
  // must resolve to the SAME {ok:false, reason:"shape"} failure the top-level
  // check already used, so the turn takes the unchanged dispatch path (never
  // a thrown exception that would abort a real customer's turn).
  //
  // QA finding 3 (2026-09-22 PR #999): validating each answer in isolation
  // left the SET of answers unchecked (empty/array/partial maps, and an
  // answer whose `type` doesn't match its question, all incorrectly passed).
  // Validation is now driven off `questions`, so every case below carries its
  // own `questions` alongside the `answers` it validates, and a shared
  // `validAnswers()` baseline is cloned + mutated one field at a time so each
  // test still isolates exactly the mutation it names.
  describe("nested answer-shape validation", () => {
    const QUESTIONS: Record<string, unknown> = {
      resolution_path: { type: "choice", criteria: { caroline_tool: "x", ask_customer: "y", no_reply: "z" } },
      off_topic_or_bad_faith: { type: "noul", criteria: { false: "x", true: "y" } },
      frustration: { type: "score", criteria: ["Calm", "Concerned", "Frustrated", "Angry"] },
    };

    function validAnswers(): Record<string, unknown> {
      return {
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.8, ask_customer: 0.2 }, confidence: 0.8 },
        off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
        frustration: { type: "score", score: 1, legend: { "0": "Calm", "1": "Concerned" }, confidence: 0.9 },
      };
    }

    async function run(answers: unknown, questions: Record<string, unknown> = QUESTIONS) {
      const fetchImpl = vi.fn(async () => ({
        ok: true,
        status: 200,
        json: async () => ({ model: "jev-1.13.0", answers }),
      })) as unknown as typeof fetch;
      const warned: string[] = [];
      const result = await callJev({ ...BASE_INPUT, questions, fetchImpl, log: { warn: (m) => warned.push(m) } });
      return { result, warned };
    }

    it("succeeds for a well-formed multi-answer response matching its own question set", async () => {
      const { result } = await run(validAnswers());
      expect(result.ok).toBe(true);
    });

    it("still succeeds for a well-formed choice answer with no probabilities/confidence at all (optional fields)", async () => {
      const answers = validAnswers();
      answers.resolution_path = { type: "choice", choice: "caroline_tool" };
      const { result } = await run(answers);
      expect(result.ok).toBe(true);
    });

    const shapeCases: Array<[string, (a: Record<string, unknown>) => void]> = [
      ["choice: confidence is a string", (a) => { (a.resolution_path as any).confidence = "0.8"; }],
      ["choice: probabilities is not an object", (a) => { (a.resolution_path as any).probabilities = "bad"; }],
      ["choice: missing choice", (a) => { delete (a.resolution_path as any).choice; }],
      ["choice: choice is an empty string", (a) => { (a.resolution_path as any).choice = ""; }],
      ["choice: probabilities does not contain the chosen key", (a) => { (a.resolution_path as any).probabilities = { ask_customer: 0.8 }; }],
      ["choice: a probabilities value is out of [0,1]", (a) => { (a.resolution_path as any).probabilities = { caroline_tool: 1.5 }; }],
      ["choice: a probabilities key is outside the question's declared criteria", (a) => { (a.resolution_path as any).probabilities = { caroline_tool: 0.8, bogus_key: 0.2 }; }],
      ["choice: choice is outside the question's declared criteria", (a) => { a.resolution_path = { type: "choice", choice: "bogus_choice" }; }],
      ["noul: noul is a string", (a) => { (a.off_topic_or_bad_faith as any).noul = "0.9"; }],
      ["noul: noul is out of [0,1]", (a) => { (a.off_topic_or_bad_faith as any).noul = 1.2; }],
      ["score: score is not a number", (a) => { (a.frustration as any).score = "high"; }],
      ["score: legend is not an object", (a) => { (a.frustration as any).legend = "bad"; }],
      ["score: confidence is a string", (a) => { (a.frustration as any).confidence = "high"; }],
      ["score: score is outside the question's declared range", (a) => { (a.frustration as any).score = 99; }],
      ["score: a legend key is outside the question's declared range", (a) => { (a.frustration as any).legend = { "99": "nope" }; }],
      ["score: a probabilities key is outside the question's declared range", (a) => { (a.frustration as any).probabilities = { "99": 1.0 }; }],
      ["unknown type", (a) => { (a.resolution_path as any).type = "mystery"; }],
      ["non-object answer", (a) => { a.resolution_path = "caroline_tool"; }],
      ["type mismatch: choice question answered as noul", (a) => { a.resolution_path = { type: "noul", noul: 0.5 }; }],
      ["type mismatch: score question answered as choice", (a) => { a.frustration = { type: "choice", choice: "Calm" }; }],
      ["type mismatch: noul question answered as score", (a) => { a.off_topic_or_bad_faith = { type: "score", score: 0 }; }],
    ];

    it.each(shapeCases)("returns ok:false, reason:shape for %s", async (_label, mutate) => {
      const answers = validAnswers();
      mutate(answers);
      const { result, warned } = await run(answers);
      expect(result).toEqual({ ok: false, reason: "shape", httpStatus: 200, latencyMs: expect.any(Number) });
      expect(warned).toEqual(["[intercom:jev] rc=fail reason=shape"]);
    });

    it("returns ok:false, reason:shape for an empty answers map", async () => {
      const { result } = await run({});
      expect(result).toEqual({ ok: false, reason: "shape", httpStatus: 200, latencyMs: expect.any(Number) });
    });

    it("returns ok:false, reason:shape for an answers array", async () => {
      const { result } = await run([]);
      expect(result).toEqual({ ok: false, reason: "shape", httpStatus: 200, latencyMs: expect.any(Number) });
    });

    it("returns ok:false, reason:shape for a partial answers map (a question went unanswered)", async () => {
      const answers = validAnswers();
      delete answers.frustration;
      const { result } = await run(answers);
      expect(result).toEqual({ ok: false, reason: "shape", httpStatus: 200, latencyMs: expect.any(Number) });
    });

    it("ignores extra answers keys not present in questions", async () => {
      const answers = validAnswers();
      answers.some_unasked_question = { type: "choice", choice: "anything" };
      const { result } = await run(answers);
      expect(result.ok).toBe(true);
    });

    it("succeeds against the real generated caroline-questions.json fixture, so a future question-set change the validator can't satisfy fails this test", async () => {
      const realAnswers = {
        first_tool: { type: "choice", choice: "credit_verification_check" },
        frustration: { type: "score", score: 0, legend: { "0": "Calm" } },
        intent: { type: "choice", choice: "credit_verification" },
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool" },
        skill: { type: "choice", choice: "customer-credit-verification" },
      };
      const { result } = await run(realAnswers, carolineQuestions as unknown as Record<string, unknown>);
      expect(result.ok).toBe(true);
    });
  });
});
