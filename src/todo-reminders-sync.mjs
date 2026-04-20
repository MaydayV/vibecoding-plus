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
          const edited = await client.editReminder(item.appleId, {
            title: item.title,
            completed: item.completed
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

        const created = await client.addReminder({
          title: item.title,
          completed: item.completed
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
      presentAppleIds.add(reminder.id);
      const result = todoService.applyRemoteReminder({
        appleId: reminder.id,
        title: reminder.title,
        completed: reminder.completed,
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
    getStatus: snapshotStatus,
    isEnabled: () => enabled
  };
}
