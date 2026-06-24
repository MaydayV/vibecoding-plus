import test from "node:test";
import assert from "node:assert/strict";

import { createTodoAssistant } from "../src/todo-assistant.mjs";

test("TodoAssistant asks for missing create title and uses follow-up as title", async () => {
  const assistant = createTodoAssistant({ todoIntentProvider: "rules" });

  const first = await assistant.interpret("添加计划");
  assert.equal(first.ok, true);
  assert.equal(first.action, "ask");
  assert.match(first.message, /计划内容/);
  assert.deepEqual(first.pendingIntent, { action: "create", missing: "text" });

  const second = await assistant.interpret("买牛奶", { pendingIntent: first.pendingIntent });
  assert.equal(second.action, "ask");
  assert.match(second.message, /提醒时间/);
  assert.deepEqual(second.pendingIntent, { action: "create", missing: "dueAt", text: "买牛奶" });

  const third = await assistant.interpret("明天早上9点", { pendingIntent: second.pendingIntent });
  assert.equal(third.command.action, "create");
  assert.equal(third.command.text, "买牛奶");
  assert.ok(third.command.dueAt);
  assert.ok(Number.isFinite(Date.parse(third.command.dueAt)));
  assert.equal(third.pendingIntent, null);
});

test("TodoAssistant asks for missing update title after index follow-up", async () => {
  const assistant = createTodoAssistant({ todoIntentProvider: "rules" });

  const first = await assistant.interpret("修改计划");
  assert.deepEqual(first.pendingIntent, { action: "update", missing: "index" });

  const second = await assistant.interpret("第二个", { pendingIntent: first.pendingIntent });
  assert.deepEqual(second.pendingIntent, { action: "update", missing: "text", index: 2 });
  assert.match(second.message, /新的计划内容/);

  const third = await assistant.interpret("发版本", { pendingIntent: second.pendingIntent });
  assert.deepEqual(third.command, {
    action: "update",
    index: 2,
    text: "发版本",
    completed: undefined
  });
});

test("TodoAssistant uses DeepSeek fallback for natural create phrasing", async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  globalThis.fetch = async (url, options) => {
    assert.equal(url, "https://api.deepseek.com/chat/completions");
    assert.equal(options.method, "POST");
    const body = JSON.parse(options.body);
    assert.equal(body.model, "deepseek-chat");
    assert.match(body.messages[1].content, /帮我记一下明天早上9点买牛奶/);
    return new Response(JSON.stringify({
      choices: [
        {
          message: {
            content: JSON.stringify({
              type: "command",
              action: "create",
              text: "明天早上9点买牛奶"
            })
          }
        }
      ]
    }));
  };

  const assistant = createTodoAssistant({
    todoIntentProvider: "deepseek",
    todoIntentApiKey: "test-key",
    todoIntentModel: "deepseek-chat",
    todoIntentBaseUrl: "https://api.deepseek.com",
    todoIntentTimeoutMs: 1000
  });

  const result = await assistant.interpret("帮我记一下明天早上9点买牛奶");
  assert.equal(result.command.action, "create");
  assert.equal(result.command.text, "明天早上9点买牛奶");
  assert.ok(result.command.dueAt);
  assert.ok(Number.isFinite(Date.parse(result.command.dueAt)));
  assert.equal(result.source, "deepseek");
});


test("TodoAssistant asks for due time when create command has no time", async () => {
  const assistant = createTodoAssistant({ todoIntentProvider: "rules" });

  const first = await assistant.interpret("添加计划 买牛奶");
  assert.equal(first.action, "ask");
  assert.match(first.message, /提醒时间/);
  assert.deepEqual(first.pendingIntent, { action: "create", missing: "dueAt", text: "买牛奶" });

  const second = await assistant.interpret("后天晚上8点", { pendingIntent: first.pendingIntent });
  assert.equal(second.command.action, "create");
  assert.equal(second.command.text, "买牛奶");
  assert.ok(second.command.dueAt);
  assert.ok(Number.isFinite(Date.parse(second.command.dueAt)));
});

test("TodoAssistant maps relaxed LLM fields to command schema", async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  globalThis.fetch = async () => new Response(JSON.stringify({
    choices: [
      {
        message: {
          content: JSON.stringify({
            action: "add",
            task: "明天上午给客户回电话"
          })
        }
      }
    ]
  }));

  const assistant = createTodoAssistant({
    todoIntentProvider: "deepseek",
    todoIntentApiKey: "test-key"
  });

  const result = await assistant.interpret("帮我记一下明天上午给客户回电话");
  assert.equal(result.action, "ask");
  assert.match(result.message, /提醒时间/);
  assert.deepEqual(result.pendingIntent, {
    action: "create",
    missing: "dueAt",
    text: "明天上午给客户回电话"
  });
});

test("TodoAssistant maps relaxed toggle payload to toggle command", async (t) => {
  const originalFetch = globalThis.fetch;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  globalThis.fetch = async () => new Response(JSON.stringify({
    choices: [
      {
        message: {
          content: JSON.stringify({
            action: "complete",
            item_index: "2"
          })
        }
      }
    ]
  }));

  const assistant = createTodoAssistant({
    todoIntentProvider: "deepseek",
    todoIntentApiKey: "test-key"
  });

  const result = await assistant.interpret("把第二个计划标记完成");
  assert.deepEqual(result.command, {
    action: "toggle",
    index: 2,
    text: "",
    completed: true
  });
});

