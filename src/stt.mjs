import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { WebSocket } from "ws";

import { projectRoot } from "./paths.mjs";
import { pcm16MonoToWav } from "./wav.mjs";

const STT_REQUEST_TIMEOUT_MS = 45000;

async function saveDebugWavIfNeeded(wavBuffer, enabled) {
  if (!enabled) {
    return null;
  }

  const dir = path.join(projectRoot, "tmp");
  await fs.mkdir(dir, { recursive: true });
  const filePath = path.join(dir, `segment-${Date.now()}.wav`);
  await fs.writeFile(filePath, wavBuffer);
  return filePath;
}

function timeoutSignal(timeoutMs = STT_REQUEST_TIMEOUT_MS) {
  return AbortSignal.timeout(Math.max(1000, Number(timeoutMs) || STT_REQUEST_TIMEOUT_MS));
}

function splitArgs(value) {
  return String(value || "")
    .trim()
    .split(/\s+/u)
    .filter(Boolean);
}

function runCommand(command, args, timeoutMs = STT_REQUEST_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
    }, Math.max(1000, Number(timeoutMs) || STT_REQUEST_TIMEOUT_MS));

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });

    child.on("exit", (code) => {
      clearTimeout(timer);
      if (timedOut) {
        reject(new Error(`Command timed out: ${command}`));
        return;
      }
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      reject(new Error(stderr.trim() || stdout.trim() || `${command} exited with code ${code}`));
    });
  });
}

export async function transcribePcm16Mono({ pcmBuffer, config }) {
  if (!pcmBuffer || pcmBuffer.length === 0) {
    return "";
  }

  const wav = pcm16MonoToWav(pcmBuffer);
  await saveDebugWavIfNeeded(wav, config.saveDebugWav);

  if (config.mockTranscript) {
    return config.mockTranscript;
  }

  const provider = resolveProvider(config);
  if (provider === "openai") {
    return await transcribeWithOpenAI(wav, config);
  }
  if (provider === "volcengine") {
    return await transcribeWithVolcengine(wav, config);
  }
  if (provider === "whisper_cpp") {
    return await transcribeWithWhisperCpp(wav, config);
  }
  if (provider === "qwen_asr") {
    return await transcribeWithQwenAsr(wav, config);
  }

  throw new Error("No STT provider is configured. Set STT_PROVIDER or provider-specific keys.");
}

function resolveProvider(config) {
  if (config.sttProvider) {
    return String(config.sttProvider).toLowerCase();
  }
  if (config.qwenAsrModel) {
    return "qwen_asr";
  }
  if (config.openaiApiKey) {
    return "openai";
  }
  if (config.volcengineAppKey && config.volcengineAccessKey) {
    return "volcengine";
  }
  return "";
}

function buildQwenAsrPrompt(config) {
  const parts = [
    "请将音频准确转写为中文文本。",
    "只输出转写结果，不要解释。"
  ];
  const language = String(config.qwenAsrLanguage || "").trim();
  if (language) {
    parts.push(`语言提示：${language}`);
  }
  const extraPrompt = String(config.qwenAsrPrompt || "").trim();
  if (extraPrompt) {
    parts.push(extraPrompt);
  }
  return parts.join("\n");
}

function extractQwenRealtimeTranscript(event) {
  if (!event || typeof event !== "object") {
    return "";
  }

  if (event.type === "conversation.item.input_audio_transcription.completed") {
    const completed = String(event.transcript || event.text || event.output_text || "").trim();
    if (completed) {
      return completed;
    }
  }

  const direct = String(event.transcript || event.text || event.output_text || event.response_text || "").trim();
  if (direct) {
    return direct;
  }

  if (Array.isArray(event.results)) {
    const mergedResults = event.results
      .map((item) => {
        if (!item || typeof item !== "object") {
          return "";
        }
        return String(item.transcript || item.text || item.output_text || "");
      })
      .join(" ")
      .trim();
    if (mergedResults) {
      return mergedResults;
    }
  }

  if (Array.isArray(event.output)) {
    const mergedOutput = event.output
      .map((item) => {
        if (!item || typeof item !== "object") {
          return "";
        }
        if (Array.isArray(item.content)) {
          return item.content
            .map((part) => {
              if (typeof part === "string") {
                return part;
              }
              if (part && typeof part === "object") {
                return String(part.transcript || part.text || part.output_text || "");
              }
              return "";
            })
            .join(" ");
        }
        return String(item.transcript || item.text || item.output_text || "");
      })
      .join(" ")
      .trim();
    if (mergedOutput) {
      return mergedOutput;
    }
  }

  return "";
}

async function transcribeWithQwenAsr(wavBuffer, config) {
  return await transcribeWithQwenAsrRealtime(wavBuffer, config);
}

async function transcribeWithQwenAsrRealtime(wavBuffer, config) {
  const model = String(config.qwenAsrModel || "").trim();
  if (!model) {
    throw new Error("QWEN_ASR_MODEL is not set");
  }

  const apiKey = String(config.qwenAsrApiKey || "").trim();
  if (!apiKey) {
    throw new Error("QWEN_ASR_API_KEY is not set");
  }

  const baseUrl = String(config.qwenAsrRealtimeBaseUrl || "").replace(/\/+$/u, "");
  if (!baseUrl) {
    throw new Error("QWEN_ASR_REALTIME_BASE_URL is not set");
  }

  const url = `${baseUrl}?model=${encodeURIComponent(model)}`;
  const sampleRate = Math.max(8000, Number(config.qwenAsrSampleRate) || 16000);
  const timeoutMs = Math.max(1000, Number(config.qwenAsrTimeoutMs) || STT_REQUEST_TIMEOUT_MS);
  const language = String(config.qwenAsrLanguage || "").trim();
  const prompt = String(config.qwenAsrPrompt || "").trim();
  const pcm = wavBuffer.subarray(44);

  return await new Promise((resolve, reject) => {
    let finished = false;
    let transcript = "";

    const finish = (error, text = "") => {
      if (finished) {
        return;
      }
      finished = true;
      clearTimeout(timer);
      ws.removeAllListeners();
      try {
        ws.close();
      } catch {
        // ignore close failure
      }

      if (error) {
        reject(error);
        return;
      }

      const result = String(text || "").trim();
      if (!result) {
        reject(new Error("Qwen ASR (realtime) returned empty transcript"));
        return;
      }
      resolve(result);
    };

    const timer = setTimeout(() => {
      finish(new Error("Qwen ASR (realtime) request timed out"));
    }, timeoutMs);

    const ws = new WebSocket(url, {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "OpenAI-Beta": "realtime=v1"
      }
    });

    ws.on("error", (error) => {
      const message = error instanceof Error ? error.message : String(error);
      finish(new Error(`Qwen ASR (realtime) websocket error: ${message}`));
    });

    ws.on("open", () => {
      ws.send(
        JSON.stringify({
          event_id: `event_${Date.now()}`,
          type: "session.update",
          session: {
            modalities: ["text"],
            input_audio_format: "pcm",
            sample_rate: sampleRate,
            input_audio_transcription: {
              ...(language ? { language } : {})
            },
            ...(prompt
              ? {
                  instructions: buildQwenAsrPrompt(config)
                }
              : {}),
            turn_detection: null
          }
        })
      );

      const chunkSize = Math.max(3200, Math.floor(sampleRate / 10) * 2);
      for (let offset = 0; offset < pcm.length; offset += chunkSize) {
        const chunk = pcm.subarray(offset, Math.min(offset + chunkSize, pcm.length));
        ws.send(
          JSON.stringify({
            event_id: `event_${Date.now()}_${offset}`,
            type: "input_audio_buffer.append",
            audio: chunk.toString("base64")
          })
        );
      }

      ws.send(
        JSON.stringify({
          event_id: `event_${Date.now()}_commit`,
          type: "input_audio_buffer.commit"
        })
      );
      ws.send(
        JSON.stringify({
          event_id: `event_${Date.now()}_finish`,
          type: "session.finish"
        })
      );
    });

    ws.on("message", (data) => {
      let event;
      try {
        event = JSON.parse(String(data));
      } catch {
        return;
      }

      const extracted = extractQwenRealtimeTranscript(event);
      if (extracted) {
        transcript = extracted;
      }

      if (event.type === "session.finished") {
        finish(null, transcript || extracted);
      }
    });

    ws.on("close", () => {
      if (!finished) {
        finish(null, transcript);
      }
    });
  });
}

async function transcribeWithOpenAI(wavBuffer, config) {
  if (!config.openaiApiKey) {
    throw new Error("OPENAI_API_KEY is not set");
  }

  const form = new FormData();
  form.set("model", config.openaiModel);
  form.set("task", "transcribe");
  if (config.openaiLanguage) {
    form.set("language", config.openaiLanguage);
  }
  form.set("file", new File([wavBuffer], "segment.wav", { type: "audio/wav" }));

  const openaiBaseUrl = String(config.openaiBaseUrl || "https://api.openai.com/v1").replace(/\/+$/u, "");
  let response;
  try {
    response = await fetch(`${openaiBaseUrl}/audio/transcriptions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.openaiApiKey}`
      },
      body: form,
      signal: timeoutSignal(config.openaiTranscribeTimeoutMs)
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`OpenAI transcription request failed: ${message}`);
  }

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`OpenAI transcription failed: ${response.status} ${text}`);
  }

  const payload = await response.json();
  const text = String(payload.text || "").trim();
  if (text) {
    return text;
  }
  return String(payload.transcription || payload.result || "").trim();
}

async function transcribeWithVolcengine(wavBuffer, config) {
  if (!config.volcengineAppKey || !config.volcengineAccessKey) {
    throw new Error("VOLCENGINE_APP_KEY or VOLCENGINE_ACCESS_KEY is not set");
  }

  const requestId = randomUUID();
  let response;
  try {
    response = await fetch("https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Api-App-Key": config.volcengineAppKey,
        "X-Api-Access-Key": config.volcengineAccessKey,
        "X-Api-Resource-Id": config.volcengineResourceId,
        "X-Api-Request-Id": requestId,
        "X-Api-Sequence": "-1"
      },
      body: JSON.stringify({
        user: {
          uid: config.volcengineAppKey
        },
        audio: {
          data: wavBuffer.toString("base64"),
          format: "wav",
          ...(config.volcengineLanguage ? { language: config.volcengineLanguage } : {})
        },
        request: {
          model_name: "bigmodel",
          enable_itn: true,
          enable_punc: true,
          show_utterances: false
        }
      }),
      signal: timeoutSignal(config.volcengineTimeoutMs)
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Volcengine transcription request failed: ${message}`);
  }

  const statusCode = response.headers.get("X-Api-Status-Code") || "";
  const statusMessage = response.headers.get("X-Api-Message") || "";
  const logId = response.headers.get("X-Tt-Logid") || "";

  if (!response.ok || statusCode !== "20000000") {
    const text = await response.text();
    throw new Error(
      `Volcengine transcription failed: http=${response.status} api=${statusCode} message=${statusMessage} logid=${logId} body=${text}`
    );
  }

  const payload = await response.json();
  return String(payload?.result?.text || "").trim();
}

async function transcribeWithWhisperCpp(wavBuffer, config) {
  const command = String(config.whisperCppCommand || "").trim() || "whisper-cli";
  const modelPath = String(config.whisperCppModelPath || "").trim();
  if (!modelPath) {
    throw new Error("WHISPER_CPP_MODEL_PATH is not set");
  }

  const language = String(config.whisperCppLanguage || "zh").trim() || "zh";
  const threads = Math.max(1, Number(config.whisperCppThreads) || 4);

  const dir = path.join(projectRoot, "tmp");
  await fs.mkdir(dir, { recursive: true });

  const token = `${Date.now()}-${randomUUID()}`;
  const wavPath = path.join(dir, `whisper-input-${token}.wav`);
  const outputPrefix = path.join(dir, `whisper-output-${token}`);
  const outputTxtPath = `${outputPrefix}.txt`;

  await fs.writeFile(wavPath, wavBuffer);

  const args = [
    "-m",
    modelPath,
    "-f",
    wavPath,
    "-l",
    language,
    "-t",
    String(threads),
    "-otxt",
    "-of",
    outputPrefix,
    "-nt"
  ];
  args.push(...splitArgs(config.whisperCppExtraArgs));

  try {
    const { stdout } = await runCommand(command, args, config.whisperCppTimeoutMs);

    try {
      const fromFile = String(await fs.readFile(outputTxtPath, "utf8") || "").trim();
      if (fromFile) {
        return fromFile;
      }
    } catch {
      // ignore file read failure, fallback to stdout
    }

    const fromStdout = String(stdout || "")
      .split(/\r?\n/u)
      .map((line) => line.replace(/^\[[^\]]+\]\s*/u, "").trim())
      .filter(Boolean)
      .join(" ")
      .trim();
    return fromStdout;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`whisper.cpp transcription failed: ${message}`);
  } finally {
    await Promise.allSettled([
      fs.unlink(wavPath),
      fs.unlink(outputTxtPath),
      fs.unlink(`${outputPrefix}.srt`),
      fs.unlink(`${outputPrefix}.vtt`),
      fs.unlink(`${outputPrefix}.json`)
    ]);
  }
}
