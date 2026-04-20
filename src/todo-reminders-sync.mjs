import { createRemindctlClient } from "./reminders-sync.mjs";

function nowIso() {
  return new Date().toISOString();
}

function mapMessage(error, fallback) {
  if (!error) {
    return fallback;
  }
  const text = String(error.message || error).trim();
  if (!text) {
    return fallback;
  }
  return text;
}

export function createTodoRemindersSync(options) {
  const {
    config,
    todoService,
    onStateChanged = () => {},
    onStatusChanged = () => {},
    logger = () => {}
  } = options;

  const enabled = Boolean(config.remindersSyncEnabled);
  const client = createRemindctlClient(config);
  const pollIntervalMs = Math.max(5000, Number(config.remindersPollSec || 15) * 1000);

  let timer = null;
  let busy = false;
  let lastSyncAt = "";
  let lastError = "";
  let syncCount = 0;

  function snapshotStatus() {
    return {
      enabled,
      command: client.command,
      list: client.listName,
      pollSec: Math.max(1, Math.round(pollIntervalMs / 1000)),
      busy,
      lastSyncAt,
      lastError,
      syncCount
    };
  }

  function emitStatus() {
    onStatusChanged(snapshotStatus());
  }

  async function pushLocalChanges() {
    const dirtyItems = todoService.getDirtySyncItems();
    if (dirtyItems.length === 0) {
      return false;
    }

    let changed = false;
    for (const item of dirtyItems) {
      try {
        if (item.appleId) {
          if (item.completed) {
            await client.deleteReminder(item.appleId);
            continue;
          }
          const edited = await client.editReminder(item.appleId, {
            title: item.title,
            completed: false
          });
          const marked = todoService.markItemSynced(item.id, {
            appleId: edited.id || item.appleId,
            syncedAt: edited.updatedAt || nowIso()
          });
          if (marked.changed) {
            changed = true;
          }
          continue;
        }

        if (item.completed) {
          continue;
        }

        const created = await client.addReminder({
          title: item.title,
          completed: false
        });
        const marked = todoService.markItemSynced(item.id, {
          appleId: created.id,
          syncedAt: created.updatedAt || nowIso()
        });
        if (marked.changed) {
          changed = true;
        }
      } catch (error) {
        logger("reminders push failed", item.id, mapMessage(error, "sync_failed"));
      }
    }

    return changed;
  }

  async function pullRemoteChanges() {
    const reminders = await client.listReminders();
    const presentAppleIds = new Set();
    let changed = false;

    for (const reminder of reminders) {
      if (reminder.completed) {
        continue;
      }
      presentAppleIds.add(reminder.id);
      const result = todoService.applyRemoteReminder({
        appleId: reminder.id,
        title: reminder.title,
        completed: false,
        updatedAt: reminder.updatedAt
      });
      if (result.changed) {
        changed = true;
      }
    }

    const prune = todoService.pruneRemoteMissingAppleIds(presentAppleIds);
    if (prune.changed) {
      changed = true;
    }

    return changed;
  }

  async function deleteRemoteReminders(appleIds = []) {
    const targets = Array.from(new Set((Array.isArray(appleIds) ? appleIds : [])
      .map((value) => String(value || "").trim())
      .filter(Boolean)));
    if (targets.length === 0) {
      return { ok: true, deleted: 0, failed: 0, errors: [] };
    }

    let deleted = 0;
    let failed = 0;
    const errors = [];
    for (const appleId of targets) {
      try {
        await client.deleteReminder(appleId);
        deleted += 1;
      } catch (error) {
        failed += 1;
        errors.push({ appleId, message: mapMessage(error, "delete_failed") });
      }
    }

    return {
      ok: failed === 0,
      deleted,
      failed,
      errors
    };
  }

  async function runSyncOnce({ reason = "manual" } = {}) {
    if (!enabled) {
      return {
        ok: false,
        skipped: true,
        reason: "disabled",
        status: snapshotStatus()
      };
    }
    if (busy) {
      return {
        ok: false,
        skipped: true,
        reason: "busy",
        status: snapshotStatus()
      };
    }

    busy = true;
    emitStatus();

    try {
      const [pushedChanged, pulledChanged] = await Promise.all([
        pushLocalChanges(),
        pullRemoteChanges()
      ]);

      const changed = Boolean(pushedChanged || pulledChanged);
      lastSyncAt = nowIso();
      lastError = "";
      syncCount += 1;
      if (changed) {
        onStateChanged();
      }

      logger("reminders sync done", reason, changed ? "changed" : "unchanged");
      return {
        ok: true,
        changed,
        reason,
        status: snapshotStatus()
      };
    } catch (error) {
      lastError = mapMessage(error, "reminders_sync_failed");
      logger("reminders sync error", lastError);
      return {
        ok: false,
        error: lastError,
        reason,
        status: snapshotStatus()
      };
    } finally {
      busy = false;
      emitStatus();
    }
  }

  function start() {
    if (!enabled) {
      emitStatus();
      return;
    }
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    timer = setInterval(() => {
      void runSyncOnce({ reason: "poll" });
    }, pollIntervalMs);
    timer.unref?.();
    emitStatus();
    void runSyncOnce({ reason: "startup" });
  }

  function stop() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    emitStatus();
  }

  return {
    start,
    stop,
    runSyncOnce,
    deleteRemoteReminders,
    getStatus: snapshotStatus,
    isEnabled: () => enabled
  };
}
