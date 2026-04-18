import test from "node:test";
import assert from "node:assert/strict";

import { detectConfiguredSttProvider, getConfigIssues } from "../src/config.mjs";

test("detectConfiguredSttProvider auto-detects whisper_cpp by model path", () => {
  const provider = detectConfiguredSttProvider({
    sttProvider: "",
    whisperCppModelPath: "/models/ggml-large-v3.bin",
    qwenAsrModel: "",
    openaiApiKey: "",
    volcengineAppKey: "",
    volcengineAccessKey: ""
  });

  assert.equal(provider, "whisper_cpp");
});

test("detectConfiguredSttProvider auto-detects qwen_asr by model", () => {
  const provider = detectConfiguredSttProvider({
    sttProvider: "",
    whisperCppModelPath: "",
    qwenAsrModel: "Qwen/Qwen3-ASR-0.6B",
    openaiApiKey: "",
    volcengineAppKey: "",
    volcengineAccessKey: ""
  });

  assert.equal(provider, "qwen_asr");
});

test("getConfigIssues validates whisper_cpp required model path", () => {
  const missing = getConfigIssues({
    mockTranscript: "",
    sttProvider: "whisper_cpp",
    whisperCppModelPath: ""
  });
  assert.deepEqual(missing, ["WHISPER_CPP_MODEL_PATH is not set."]);

  const ok = getConfigIssues({
    mockTranscript: "",
    sttProvider: "whisper_cpp",
    whisperCppModelPath: "/models/ggml-base.bin"
  });
  assert.deepEqual(ok, []);
});

test("getConfigIssues validates qwen_asr realtime requirements", () => {
  const missingModel = getConfigIssues({
    mockTranscript: "",
    sttProvider: "qwen_asr",
    qwenAsrModel: "",
    qwenAsrApiKey: "sk-test",
    qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
  });
  assert.deepEqual(missingModel, ["QWEN_ASR_MODEL is not set."]);

  const missingApiKey = getConfigIssues({
    mockTranscript: "",
    sttProvider: "qwen_asr",
    qwenAsrModel: "qwen3-asr-flash-realtime",
    qwenAsrApiKey: "",
    qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
  });
  assert.deepEqual(missingApiKey, ["QWEN_ASR_API_KEY is not set."]);

  const missingBaseUrl = getConfigIssues({
    mockTranscript: "",
    sttProvider: "qwen_asr",
    qwenAsrModel: "qwen3-asr-flash-realtime",
    qwenAsrApiKey: "sk-test",
    qwenAsrRealtimeBaseUrl: ""
  });
  assert.deepEqual(missingBaseUrl, ["QWEN_ASR_REALTIME_BASE_URL is not set."]);

  const ok = getConfigIssues({
    mockTranscript: "",
    sttProvider: "qwen_asr",
    qwenAsrModel: "qwen3-asr-flash-realtime",
    qwenAsrApiKey: "sk-test",
    qwenAsrRealtimeBaseUrl: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
  });
  assert.deepEqual(ok, []);
});
