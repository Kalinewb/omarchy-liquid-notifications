// Notification service for the omarchy shell.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Notifications
import qs.Commons

import "components"
import "NotificationLogic.js" as NotificationLogic

Item {
  id: service

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  // History + DND live under XDG_STATE_HOME: they're persistent user state
  // (the notifications received, the last-set DND preference), not
  // regeneratable cache that a `rm -rf ~/.cache` should wipe.
  readonly property string stateDir: home + "/.local/state/omarchy/"
  readonly property string settingsPath: stateDir + "notifications.json"
  // One file per on-screen popup, so live toasts survive shell restarts.
  // A file exists exactly as long as its popup is showing: written when the
  // toast appears, moved into historyDir when it expires, is dismissed, or is
  // acted upon.
  readonly property string popupStateDir: stateDir + "notifications/"
  // The notifications that already left the screen, one file each, trimmed to
  // the newest historyLimit. This directory IS the history: `showHistory`
  // replays exactly what has been moved in here.
  readonly property string historyDir: popupStateDir + "history/"
  // Copies of the avatars/images persisted entries reference — the sender's
  // originals don't outlive the notification (see persistablePopup). Each
  // copy lives and dies with the JSON file whose stem it carries.
  readonly property string imagesDir: popupStateDir + "images/"
  // Corner radius is shared with the menu and shell panels.
  // It mirrors Hyprland's current decoration:rounding value.
  readonly property int cornerRadius: Style.cornerRadius
  // Toasts render on the Overlay layer, above the bar, and sit flush against
  // the true physical screen edge on every side they touch -- zero margin,
  // matching the flush-corner shape language, not a bar-clearance gap. This
  // deliberately overlaps a top/left/right bar rather than leaving a gap
  // below it: earlier revisions cleared the bar (or later, used a small
  // Style.gapsOut gap) and both still read as "floating near the corner"
  // instead of "in the actual corner" per live feedback with screenshots.

  // Live Notification objects by originalId, kept OUT of the ListModels: a
  // QObject stored in a model role becomes a dangling C++ pointer when the
  // server destroys the notification (sender close, DND untrack, dismiss),
  // and the next read of that role segfaults in QQmlListModel::data. A JS
  // map only holds a wrapper, which degrades to a catchable error instead.
  property var liveRefs: ({})

  // PersistentProperties handles in-process QML reloads. The on-disk
  // notifications.json file is the cross-restart backstop — its `dnd` key
  // is hydrated into persisted.doNotDisturb on startup and written back via
  // a debounced save timer.
  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-notifications"
    property bool doNotDisturb: false
    // Which screen corner the popup stack grows out of: "left", "center", or
    // "right" (default -- keep in sync with NotificationLogic.js's
    // POPUP_CORNERS; not read from there directly because
    // PersistentProperties evaluates its property initializers in a context
    // where the JS module import isn't reliably resolved yet, which surfaced
    // as a silent "Unable to assign [undefined] to QString" on reload).
    // Purely cosmetic -- unlike doNotDisturb it never needs a DND-style
    // bypass, just somewhere for the Dynamic-Island-style toasts to be
    // anchored to.
    property string popupCorner: "right"
    onDoNotDisturbChanged: {
      // Suppress the write that load-time hydration would otherwise trigger.
      if (service._hydrating) return
      service.scheduleSettingsSave()
    }
    onPopupCornerChanged: {
      if (service._hydrating) return
      service.scheduleSettingsSave()
    }
  }

  // Guards onDoNotDisturbChanged/onPopupCornerChanged while we're hydrating
  // from disk so the hydration assignment doesn't immediately schedule a
  // write-back.
  property bool _hydrating: false

  readonly property alias doNotDisturb: persisted.doNotDisturb
  readonly property alias popupCorner: persisted.popupCorner

  function setDoNotDisturb(value) {
    persisted.doNotDisturb = !!value
  }

  // Only "left", "center", "right" are accepted; anything else is ignored
  // rather than persisting a corner the layout code below doesn't know how
  // to draw.
  function setPopupCorner(value) {
    var corner = String(value || "")
    if (!NotificationLogic.isValidPopupCorner(corner)) return false
    persisted.popupCorner = corner
    return true
  }

  // popupModel feeds the on-screen toast stack — the only model the service
  // keeps. Everything a toast leaves behind lives on disk under historyDir.
  //
  // Aliased as a property so consumers outside this Item's id scope can bind
  // to it. QML ids aren't visible to external consumers without the alias.
  property alias popupModel: popupModel
  ListModel { id: popupModel }

  // How many notifications the history directory keeps, and therefore how
  // many `showHistory` can replay.
  readonly property int historyLimit: 10

  readonly property int lowPopupDuration: 5000
  readonly property int normalPopupDuration: 8000
  readonly property int maxPopupDuration: 30000

  function durationFor(urgency, expireTimeout) {
    switch (urgency) {
    case NotificationUrgency.Critical:
      return 0
    case NotificationUrgency.Low:
      return Math.min(maxPopupDuration, Math.max(lowPopupDuration, requestedDuration(expireTimeout)))
    default:
      return Math.min(maxPopupDuration, Math.max(normalPopupDuration, requestedDuration(expireTimeout)))
    }
  }

  function requestedDuration(expireTimeout) {
    // FreeDesktop notification spec (and Quickshell) report expireTimeout in
    // milliseconds, so pass it through directly.
    var ms = Number(expireTimeout || 0)
    if (!isFinite(ms) || ms <= 0) return 0
    return Math.round(ms)
  }

  // DND bypass: only let through notifications we trust to be intentional
  // and rare.
  //   - omarchy-action: a user-action confirmation toast ("Theme changed",
  //     "Screenshot saved"). The user JUST did something — their feedback
  //     should show.
  //   - urgency=critical AND app_name=notify-send: bare-CLI emergency alerts.
  //     Trusted because it's almost always omarchy or system shell scripts —
  //     chat apps set app_name to their brand (Discord/Slack/Vesktop), which
  //     falls outside this rule.
  function shouldBypassDnd(notification) {
    return NotificationLogic.shouldBypassDnd(notification, NotificationUrgency.Critical)
  }

  function snapshotOf(notification) {
    return NotificationLogic.snapshotOf(notification, Date.now())
  }

  // A notification nobody looks back at:
  //   - the freedesktop `transient` hint is set ("popup only, don't store")
  //   - app_name is "notify-send" (the CLI default — means the sender
  //     didn't bother declaring an identity, so it's almost certainly
  //     ephemeral test/feedback noise)
  //   - app_name is "omarchy-action" (Omarchy's own user-action toasts —
  //     the user just triggered them)
  // Their toasts still land in history like any other once they've been on
  // screen; the distinction only decides whether a DND-silenced one is worth
  // recording at all.
  function isEphemeral(notification) {
    var transient = false
    try {
      transient = !!(notification.hints && notification.hints["transient"])
    } catch (e) { transient = false }
    return transient || NotificationLogic.isEphemeralApp(String(notification.appName || ""))
  }

  function handleNotification(notification) {
    // Without `tracked = true` the Notification object is destroyed as soon
    // as this signal handler returns, which would null out the `ref` we just
    // captured for the popup card.
    notification.tracked = true
    var snapshot = snapshotOf(notification)
    liveRefs[snapshot.originalId] = notification
    // Guard the delete: a newer notification may have reused this originalId
    // (freedesktop replaces_id) and taken over the map slot.
    notification.closed.connect(function() {
      if (service.liveRefs[snapshot.originalId] === notification)
        delete service.liveRefs[snapshot.originalId]
    })

    // DND bypass rules: chat apps abuse urgency=critical to force
    // visibility, so critical alone isn't enough — we also require the
    // sender to be CLI-style. See shouldBypassDnd().
    if (service.doNotDisturb && !shouldBypassDnd(notification)) {
      // The toast never shows, so the only record a silenced notification
      // can leave is a history entry. Write it straight into history —
      // "what did I miss while silenced" is exactly what history is for.
      if (!isEphemeral(notification)) {
        writeSilenced(notification, snapshot)
        return
      }
      delete liveRefs[snapshot.originalId]
      notification.tracked = false
      return
    }

    persistPopupFile(snapshot)
    watchForUpdates(notification, snapshot)
    // Qt.callLater avoids "QV4::Object::insertMember" crashes when a
    // Repeater is mid-incubation while we mutate its model.
    Qt.callLater(function() {
      removePopupsByOriginalId(snapshot.originalId, NotificationLogic.popupFileName(snapshot))
      popupModel.insert(0, snapshot)
      // An update that arrived while the insert was deferred found no row to
      // write to, and a property that already changed will not change again.
      // Reading the object once the row exists catches up on it.
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    })
  }

  // Persist a silenced notification, held tracked until its content is
  // stable: untracking tells the sender its notification closed (Chromium
  // then deletes its avatar file), and a replaces_id update lands on this
  // object without a second onNotification — releasing on a stale snapshot
  // would drop it. Each catch-up write reuses the original file identity.
  function writeSilenced(notification, written) {
    writeHistoryFile(written, function() {
      var updated = null
      try {
        updated = NotificationLogic.replacementSnapshot(notification, written.originalId, written.timestamp)
      } catch (e) {
        // Torn down by the server while the write was queued.
      }
      if (updated && NotificationLogic.popupRowChanged(written, updated)) {
        service.writeSilenced(notification, updated)
        return
      }
      service.releaseSilenced(notification, written.originalId)
    })
  }

  // Let go of a DND-silenced notification once its history write has run.
  // The id may have been reused and the object torn down meanwhile.
  function releaseSilenced(notification, originalId) {
    if (liveRefs[originalId] === notification) delete liveRefs[originalId]
    try {
      notification.tracked = false
    } catch (e) {
      // Object already destroyed by the server — nothing left to release.
    }
  }

  // Everything the card draws. A change to any of these is a client updating
  // the notification in place, which is the only kind of update we ever hear
  // about after the popup exists.
  readonly property var updateSignals: [
    "summaryChanged", "bodyChanged", "appNameChanged", "appIconChanged",
    "imageChanged", "urgencyChanged", "expireTimeoutChanged", "hintsChanged"
  ]

  // A client that updates a notification through replaces_id does not produce
  // a second onNotification: the server writes the new content onto the object
  // we are already holding. The card draws a snapshot copied out of that
  // object — deliberately, since the object itself must stay out of the model
  // — so nothing reaches the screen until we copy it again.
  function watchForUpdates(notification, snapshot) {
    function refresh() {
      service.refreshPopup(notification, snapshot.originalId, snapshot.timestamp)
    }

    for (var i = 0; i < updateSignals.length; i++) {
      var signal = notification[updateSignals[i]]
      if (signal && typeof signal.connect === "function") signal.connect(refresh)
    }
  }

  function refreshPopup(notification, originalId, timestamp) {
    // A newer notification may have taken this id over, and the object may
    // outlive its popup — in both cases there is nothing here to refresh.
    if (service.liveRefs[originalId] !== notification) return

    var updated
    try {
      updated = NotificationLogic.replacementSnapshot(notification, originalId, timestamp)
    } catch (e) {
      // Object torn down by the server while the signal was in flight.
      return
    }

    var roles = NotificationLogic.popupRoles()
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId || row.timestamp !== timestamp) continue
      if (!NotificationLogic.popupRowChanged(row, updated)) return
      for (var r = 0; r < roles.length; r++) popupModel.setProperty(i, roles[r], updated[roles[r]])
      // The file name is the timestamp and id this popup was persisted under,
      // so the rewrite lands on the same file: a restart restores the version
      // last shown, and so does the copy that ends up in history.
      persistPopupFile(updated)
      return
    }
  }

  // A restored row carries an id from the previous server generation, and
  // the new server hands out ids from 1 again — so a fresh notification
  // with the same originalId is a coincidence, not the same notification.
  // The timestamp (via the file name) disambiguates: it travels with the
  // row through every model and file round-trip.
  function isRestoredRow(row) {
    return !!row && !!restoredPopups[NotificationLogic.popupFileName(row)]
  }

  // A notification arriving under an originalId a popup on screen already
  // holds supersedes it, so that row leaves the screen. Its file is deleted
  // rather than archived: the row taking its place archives itself when it
  // goes, and history would otherwise hold two entries for what the sender
  // means as one notification.
  // keepFileName is the replacement's own file: a same-millisecond
  // replacement shares the replaced row's filename, and the new write is
  // already queued — deleting that path here would erase the replacement's
  // only file.
  function removePopupsByOriginalId(originalId, keepFileName) {
    for (var i = popupModel.count - 1; i >= 0; i--) {
      var row = popupModel.get(i)
      if (!row || row.originalId !== originalId) continue
      // Not a replaces_id match — see isRestoredRow. Removing it here
      // would silently kill a restored critical alert on an unrelated ping.
      if (isRestoredRow(row)) continue
      if (NotificationLogic.popupFileName(row) !== keepFileName) deletePopupFileFor(row)
      popupModel.remove(i)
    }
  }

  function dismissPopup(index) {
    removePopup(index, "dismiss")
  }

  function expirePopup(index) {
    removePopup(index, "expire")
  }

  function removePopup(index, reason) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)
    var originalId = entry ? entry.originalId : -1
    // A restored row has no live server object, and its old-generation id
    // may meanwhile belong to a fresh notification — resolving liveRefs by
    // id would dismiss that unrelated notification at the server.
    var restored = isRestoredRow(entry)
    var ref = !restored && originalId >= 0 ? liveRefs[originalId] : null
    // The popup is leaving the screen — for any reason — so its file must not
    // survive to the next shell restart. It becomes the newest history entry
    // instead. Rows that never had a file (a history replay, the empty-history
    // placeholder) archive to nothing, which the move tolerates.
    if (entry) {
      archivePopupFileFor(entry)
      if (restored) delete restoredPopups[NotificationLogic.popupFileName(entry)]
    }
    popupModel.remove(index)
    if (ref) {
      try {
        if (ref.tracked) {
          if (reason === "expire" && typeof ref.expire === "function") ref.expire()
          else ref.dismiss()
        }
      } catch (e) {
        // Object already torn down by the server — nothing to dismiss.
      }
    }
  }

  function clearPopups() {
    while (popupModel.count > 0) dismissPopup(0)
  }

  // Run the popup's click action, then dismiss. Omarchy's own toasts carry the
  // action as an argv vector in the `execArgv` role (see execArgvFromHints),
  // which the persistence files preserve, so restored toasts stay clickable.
  // Third-party clients register a libnotify action under the canonical
  // identifier "default" instead; that one only works while the sender is live.
  function invokePopupDefault(index) {
    if (index < 0 || index >= popupModel.count) return
    var entry = popupModel.get(index)

    // Run the argv (via Util.execArgv, no shell interpretation). Detached so it
    // outlives the shell, which installer toasts depend on: they restart it.
    var argv = NotificationLogic.parseExecArgv(entry ? entry.execArgv : "")
    if (argv) {
      Util.execArgv(argv)
      dismissPopup(index)
      return
    }
    // Restored rows have no live actions, and looking up liveRefs by their
    // old-generation id could fire an unrelated fresh notification's action.
    var ref = entry && !isRestoredRow(entry) ? liveRefs[entry.originalId] : null
    var invoked = false
    try {
      if (ref && ref.actions) {
        for (var i = 0; i < ref.actions.length; i++) {
          var action = ref.actions[i]
          if (action && action.identifier === "default") {
            action.invoke()
            invoked = true
            break
          }
        }
      }
    } catch (e) {
      // Notification already torn down by the server — fall through to focus.
      console.warn("invoke default failed:", e)
    }
    // Chat apps (Slack, Discord, Vesktop, etc.) rarely register a "default"
    // libnotify action — they just expect clicking the notification to
    // focus their window. Fall back to focusing the sending app by class so
    // that click-to-jump actually works.
    if (!invoked) focusApp(entry)
    dismissPopup(index)
  }

  // Try to focus an existing Hyprland window matching the notification's
  // sender. The helper handles case-insensitive class matching.
  function focusApp(entry) {
    if (!entry || !entry.app) return
    focusAppProc.command = [
      service.omarchyPath + "/bin/omarchy-hyprland-focus-app",
      String(entry.app)
    ]
    focusAppProc.running = true
  }

  Process { id: focusAppProc; running: false }

  Process {
    id: ensureDirsProc
    command: ["mkdir", "-p", service.stateDir, service.popupStateDir, service.historyDir, service.imagesDir]
    running: false
  }

  // ---------------------------------------------------- popup persistence
  //
  // Mirror every on-screen popup to its own file under popupStateDir so
  // toasts survive shell restarts (notably the restart `omarchy-update`
  // performs). Writes, moves and deletes go through one serialized queue: a
  // burst of replaces_id updates must not race a single reused Process, and
  // ordering guarantees a delete issued after a write wins.

  // Popups restored from a previous shell process, keyed by their file
  // name (timestamp-originalId) since ids alone repeat across server
  // generations. The replaces_id handling and liveRefs lookups must not
  // match these rows against fresh notifications.
  property var restoredPopups: ({})

  // Entries are either { command, done } for a file job or { read: true } for
  // a replay's directory read. Queueing the read rather than running it beside
  // the queue is what makes it a barrier: it takes its place in line, so the
  // history it sees is the one that existed when the replay was asked for.
  // Everything queued after it — a clear, an archive, a silenced write — waits
  // for it, and no amount of later traffic can push it back.
  property var popupFileQueue: []

  // Done callback of the job popupFileProc is currently running.
  property var runningPopupFileJobDone: null

  function enqueuePopupFileJob(command, done) {
    popupFileQueue = popupFileQueue.concat([{ command: command, done: done || null }])
    runNextPopupFileJob()
  }

  function enqueueHistoryRead() {
    popupFileQueue = popupFileQueue.concat([{ read: true }])
    runNextPopupFileJob()
  }

  function runNextPopupFileJob() {
    if (readHistoryProc.running || popupFileProc.running) return
    if (popupFileQueue.length === 0) return

    var job = popupFileQueue[0]
    popupFileQueue = popupFileQueue.slice(1)

    if (job.read) {
      startHistoryRead()
      return
    }

    popupFileProc.command = job.command
    service.runningPopupFileJobDone = job.done || null
    popupFileProc.running = true
  }

  Process {
    id: popupFileProc
    running: false
    onExited: {
      var done = service.runningPopupFileJobDone
      service.runningPopupFileJobDone = null
      if (done) {
        try {
          done()
        } catch (e) {
          console.warn("notifications: file job callback failed:", e)
        }
      }
      service.runNextPopupFileJob()
    }
  }

  // Consumes the remaining args as from/to pairs. Bounded read into a temp
  // file, validated, then renamed into place: the source path is
  // sender-controlled and may grow, block, or become a FIFO mid-copy, and
  // must neither hang the serialized queue nor fill the state dir.
  readonly property string copyImagesScript:
    "while (( $# >= 2 )); do\n" +
    "  if [[ -f $1 ]] && timeout 5 head -c 5242881 -- \"$1\" > \"$2.tmp\" 2>/dev/null &&\n" +
    "     (( $(stat -c%s -- \"$2.tmp\") <= 5242880 )); then mv -f -- \"$2.tmp\" \"$2\"; else rm -f -- \"$2.tmp\"; fi\n" +
    "  shift 2\n" +
    "done\n"

  function persistPopupFile(snapshot) {
    // The JSON travels as an argument, not through shell interpolation, so
    // summaries/bodies with quotes or backticks can't break the command. The
    // mkdir guards notifications that arrive before ensureDirsProc has run.
    // Copies run before the JSON referencing them, while the source exists.
    var persistable = NotificationLogic.persistablePopup(snapshot, imagesDir)
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$2\" || exit 0\n" +
      "dir=\"$1\" json=\"$3\" name=\"$4\"\n" +
      "shift 4\n" +
      copyImagesScript +
      "printf '%s\\n' \"$json\" > \"$dir/$name\"", "--",
      popupStateDir,
      imagesDir,
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      NotificationLogic.popupFileName(snapshot)]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command)
  }

  function deletePopupFileFor(row) {
    if (!row) return
    // History replays and the "no recent notifications" placeholder never
    // had a file — rm -f on the computed paths is a harmless no-op there.
    enqueuePopupFileJob(["bash", "-c",
      "rm -f \"$1/$2.json\" \"$3/$2\"-*", "--",
      popupStateDir, NotificationLogic.imageStem(row), imagesDir])
  }

  // ---------------------------------------------------- history
  //
  // A popup that leaves the screen keeps its file — it just moves one level
  // down, into historyDir. Trimming happens right there in the same shell
  // job: the names sort numerically by their leading millisecond timestamp,
  // so everything but the newest historyLimit files is the tail to drop,
  // image copies included. Callers set $hist, $limit and $imgs first.
  readonly property string trimHistoryScript:
    "ls -1 \"$hist\" 2>/dev/null | sort -n | head -n \"-$limit\" | while IFS= read -r stale; do rm -f \"$hist/$stale\" \"$imgs/${stale%.json}\"-*; done"

  function archivePopupFileFor(row) {
    if (!row) return
    // A history replay or the empty-history placeholder has no file to move;
    // the failed mv leaves the history untouched, trimming included. Image
    // copies stay put — live and archived entries share imagesDir.
    enqueuePopupFileJob(["bash", "-c",
      "mkdir -p \"$1\" || exit 0\n" +
      "hist=\"$1\" limit=\"$2\" imgs=\"$5\"\n" +
      "mv -f \"$4/$3\" \"$1/$3\" 2>/dev/null || exit 0\n" +
      trimHistoryScript, "--",
      historyDir,
      String(historyLimit),
      NotificationLogic.popupFileName(row),
      popupStateDir,
      imagesDir])
  }

  // Record a notification that never made it to the screen (DND silenced it),
  // straight into history. Same file format as an archived popup, so the
  // replay can't tell the two apart.
  //
  // A silenced notification is untracked the moment it arrives, so the server
  // has nothing left for a later replaces_id to replace and hands the sender a
  // fresh id instead. Every update from a chatty thread is therefore its own
  // notification here, and several can sit in the ten slots together — there
  // is no id to recognize them by, and guessing from app and summary would
  // merge genuinely separate messages.
  function writeHistoryFile(entry, done) {
    if (!entry) {
      if (done) done()
      return
    }
    var persistable = NotificationLogic.persistablePopup(entry, imagesDir)
    var command = ["bash", "-c",
      "mkdir -p \"$1\" \"$5\" || exit 0\n" +
      "hist=\"$1\" limit=\"$2\" name=\"$3\" json=\"$4\" imgs=\"$5\"\n" +
      "shift 5\n" +
      copyImagesScript +
      "printf '%s\\n' \"$json\" > \"$hist/$name\" || exit 0\n" +
      trimHistoryScript, "--",
      historyDir,
      String(historyLimit),
      NotificationLogic.popupFileName(entry),
      NotificationLogic.serializePopup(persistable.entry, NotificationUrgency.Normal),
      imagesDir]
    for (var i = 0; i < persistable.copies.length; i++)
      command.push(persistable.copies[i].from, persistable.copies[i].to)
    enqueuePopupFileJob(command, done)
  }

  function clearHistory() {
    enqueuePopupFileJob(["bash", "-c",
      "for f in \"$1\"/*.json; do\n" +
      "  [[ -e $f ]] || continue\n" +
      "  stale=\"${f##*/}\"\n" +
      "  rm -f \"$f\" \"$2/${stale%.json}\"-*\n" +
      "done", "--", historyDir, imagesDir])
  }

  // A restart can kill a queued job between its cp and its JSON write,
  // leaving copies no JSON-derived cleanup can name. Swept at startup,
  // through the queue so in-flight copies aren't mistaken for orphans.
  function sweepOrphanImages() {
    enqueuePopupFileJob(["bash", "-c",
      "for img in \"$3\"/*; do\n" +
      "  [[ -e $img ]] || continue\n" +
      "  [[ $img == *.tmp ]] && { rm -f -- \"$img\"; continue; }\n" +
      "  stem=\"${img##*/}\"\n" +
      "  stem=\"${stem%-*}\"\n" +
      "  [[ -e $1/$stem.json || -e $2/$stem.json ]] || rm -f \"$img\"\n" +
      "done", "--", popupStateDir, historyDir, imagesDir])
  }

  Process {
    id: readHistoryProc
    running: false
    // Let the file queue go again, whatever the read did — a failed or empty
    // read must not leave archives and clears parked behind it forever.
    onExited: service.runNextPopupFileJob()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.replayHistory(text)
    }
  }

  // Toasts that were on screen when the replay was asked for. The clear in
  // replayHistory archives them, but the directory read is already in flight
  // by then, so they're handed over in memory instead of being waited for.
  property var replayCarryOver: []

  // Set from the moment a read is queued until it starts, so a second
  // showHistory while one is still waiting its turn doesn't queue another.
  property bool historyReadQueued: false

  // Re-show what's in historyDir as toasts. The read goes through the file
  // queue and its own subprocess, so the replay lands in replayHistory once
  // the work queued ahead of it has finished.
  function showRecentHistory() {
    if (readHistoryProc.running || service.historyReadQueued) return "ok"
    service.replayCarryOver = liveRowsForReplay()
    service.historyReadQueued = true
    enqueueHistoryRead()
    return "ok"
  }

  function startHistoryRead() {
    service.historyReadQueued = false
    readHistoryProc.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", historyDir]
    readHistoryProc.running = true
  }

  // Copy the on-screen rows out of the model. The placeholder from an earlier
  // empty replay carries originalId -1 and is not a notification, so it is
  // left behind rather than replayed as one. The replay dismisses these
  // notifications, and senders delete their images on close — so the carried
  // rows point at the persisted copies, like the archived files they join.
  function liveRowsForReplay() {
    var rows = []
    for (var i = 0; i < popupModel.count; i++) {
      var row = popupModel.get(i)
      if (!row || row.originalId < 0) continue
      rows.push(NotificationLogic.persistablePopup({
        id: row.id,
        originalId: row.originalId,
        app: row.app,
        appIcon: row.appIcon,
        summary: row.summary,
        body: row.body,
        image: row.image,
        glyph: row.glyph || "",
        execArgv: row.execArgv || "",
        urgency: row.urgency,
        timestamp: row.timestamp
      }, imagesDir).entry)
    }
    return rows
  }

  function replayHistory(raw) {
    var rows = NotificationLogic.historyRows(
      raw, service.replayCarryOver, NotificationUrgency.Normal, service.historyLimit)
    service.replayCarryOver = []

    // Replaying nothing at all looks like a dead keybinding, so say so.
    if (rows.length === 0) {
      popupModel.insert(0, {
        id: -1,
        originalId: -1,
        app: "omarchy-action",
        appIcon: "",
        summary: "No recent notifications",
        body: "",
        image: "",
        glyph: "󰂚",
        execArgv: "",
        urgency: NotificationUrgency.Low,
        expireTimeout: 0,
        timestamp: Date.now()
      })
      return
    }

    clearPopups()
    // Rows arrive newest-first, and index 0 is the top of the toast stack.
    for (var i = 0; i < rows.length; i++) {
      // Replayed rows are restored rows: their notification died with the
      // sender long ago, so they must never resolve to a live server object
      // that has since been handed their old id.
      service.restoredPopups[NotificationLogic.popupFileName(rows[i])] = true
      popupModel.append(rows[i])
    }
  }

  Process {
    id: restorePopupsProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.restorePopups(text)
    }
  }

  function restorePopups(raw) {
    var entries = NotificationLogic.parsePopupFiles(raw, NotificationUrgency.Normal)
    var now = Date.now()
    var live = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var duration = durationFor(entry.urgency, entry.expireTimeout)
      if (NotificationLogic.popupExpired(entry, duration, now)) {
        // It would have expired on screen had the shell kept running, so it
        // gets archived exactly like an expiry that happened while it did.
        archivePopupFileFor(entry)
        continue
      }
      // Survivors restart with a full lifetime on purpose: shell restarts
      // are rare, and a full look after the restart flicker beats resuming
      // a toast with a second left on its clock. The reset is persisted as
      // an absolute deadline so a second restart while the toast is still
      // on screen judges it by the reset clock, not the original timestamp.
      if (duration > 0) {
        entry.deadline = now + duration
        persistPopupFile(entry)
        // deadline is persistence metadata, not a model role — fresh rows
        // never carry it, and ListModel roles must stay consistent.
        delete entry.deadline
      }
      live.push(entry)
    }
    if (live.length === 0) return

    Qt.callLater(function() {
      for (var j = 0; j < live.length; j++) {
        var restored = live[j]
        // A notification received while the restore was reading the dir can
        // already occupy this originalId with the same timestamp — then it
        // IS this entry, live with its own file, and must be left alone. A
        // different timestamp is indistinguishable between a genuine
        // cross-restart replaces_id and a new-generation id coincidence, so
        // show both: a briefly duplicated toast beats silently dropping a
        // restored critical alert.
        var duplicate = false
        for (var k = 0; k < popupModel.count; k++) {
          var row = popupModel.get(k)
          if (row && row.originalId === restored.originalId && row.timestamp === restored.timestamp) {
            duplicate = true
            break
          }
        }
        if (duplicate) continue
        // Append (entries are newest-first) so restored toasts stack in
        // their original order below anything that just arrived. Restored
        // popups have no liveRefs entry — the server object died with the
        // old shell — so dismissal and action fallbacks degrade gracefully.
        service.restoredPopups[NotificationLogic.popupFileName(restored)] = true
        popupModel.append(restored)
      }
    })
  }

  // ---------------------------------------------------- settings persistence

  FileView {
    id: settingsFile
    path: service.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadSettings(text())
    // First-run: the file doesn't exist yet. Without this branch,
    // `settingsLoaded` stays false forever and `scheduleSettingsSave` becomes
    // a no-op — so the file is never created and the DND preference vanishes
    // on shell restart.
    onLoadFailed: service.loadSettings("")
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: service.flushSettings()
  }

  function scheduleSettingsSave() {
    if (!service.settingsLoaded) return
    settingsSaveTimer.restart()
  }

  property bool settingsLoaded: false

  function loadSettings(raw) {
    // FileView can fire onLoaded more than once during startup — the implicit
    // preload when `path` resolves, plus the explicit `settingsFile.reload()`
    // in Component.onCompleted can both end up calling here.
    if (service.settingsLoaded) return

    var parsed = NotificationLogic.parseSettings(raw)
    if (parsed.error) console.warn("notifications: settings parse failed:", parsed.errorMessage || "")

    if (parsed.dnd !== null) {
      service._hydrating = true
      persisted.doNotDisturb = parsed.dnd
      service._hydrating = false
    }
    if (parsed.corner !== null) {
      service._hydrating = true
      persisted.popupCorner = parsed.corner
      service._hydrating = false
    }

    service.settingsLoaded = true
    // Versions before the history moved into its own directory kept every
    // notification in here. Rewrite once so that dead payload doesn't sit in
    // the file until the next DND toggle happens to clear it.
    if (parsed.legacy) service.scheduleSettingsSave()
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({
      version: 3,
      dnd: persisted.doNotDisturb,
      corner: persisted.popupCorner
    }, null, 2) + "\n")
  }

  Component.onCompleted: {
    ensureDirsProc.running = true
    // Once mkdir has had a tick, load the existing settings file. FileView
    // surfaces an empty string when the file doesn't exist; loadSettings
    // handles that path.
    Qt.callLater(function() {
      settingsFile.reload()
      // Re-show popups that were on screen when the previous shell died.
      // The glob-through-bash tolerates a missing/empty dir (first run).
      // awk 1 (not cat) so a torn file missing its trailing newline can't
      // glue itself onto the next file and take a valid popup down with it.
      restorePopupsProc.command = ["bash", "-c",
        "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", service.popupStateDir]
      restorePopupsProc.running = true
      // Safe beside the restore read: it only re-persists entries whose
      // JSON exists, exactly the images the sweep keeps.
      service.sweepOrphanImages()
    })
  }

  // ---------------------------------------------------- IPC

  IpcHandler {
    target: "notifications"

    function dndState(): string {
      return service.doNotDisturb ? "on" : "off"
    }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      var v = String(value || "").toLowerCase()
      var on = v === "true" || v === "1" || v === "on" || v === "yes"
      service.setDoNotDisturb(on)
      return dndState()
    }

    function isDnd(): string {
      return dndState()
    }

    // Which screen corner the popup stack grows out of: "left", "center", or
    // "right".
    function getCorner(): string {
      return service.popupCorner
    }

    // Returns the corner now in effect, same as getCorner -- including when
    // an invalid value was passed, so a caller can tell the difference
    // between "changed" and "ignored" without a separate error path.
    function setCorner(value: string): string {
      service.setPopupCorner(value)
      return service.popupCorner
    }

    // Replay the notifications that have been moved into the history dir.
    function showHistory(): string {
      return service.showRecentHistory()
    }

    // `clear` forgets the recorded history; the toasts on screen stay put.
    function clear(): string {
      service.clearHistory()
      return "ok"
    }

    function dismissAll(): string {
      service.clearPopups()
      return "ok"
    }

    // Dismiss the most recent popup.
    function dismissOne(): string {
      if (popupModel.count === 0) return "none"
      service.dismissPopup(0)
      return "ok"
    }

    // Fire the default action on the most recent popup, then dismiss it.
    function invokeLast(): string {
      if (popupModel.count === 0) return "none"
      service.invokePopupDefault(0)
      return "ok"
    }

    // Take a toast off the screen by summary substring, used by the
    // first-run notifications once their action has been clicked.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var hit = false
      for (var i = popupModel.count - 1; i >= 0; i--) {
        var row = popupModel.get(i)
        if (row && String(row.summary || "").indexOf(needle) !== -1) {
          service.dismissPopup(i)
          hit = true
        }
      }
      return hit ? "ok" : "none"
    }

    function ping(): string { return "ok" }
  }

  // ---------------------------------------------------- server

  NotificationServer {
    id: server
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true

    onNotification: function(notification) {
      service.handleNotification(notification)
    }
  }

  // -------------------------------------------------------------- popup UI
  //
  // One PanelWindow per output (Variants on Quickshell.screens) holding the
  // stacked toast cards. Layer is Overlay, exclusionMode Ignore, no
  // keyboard focus — popups are passive surfaces and must never steal input
  // from the focused application.

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: popupWindow
      required property var modelData
      screen: modelData
      visible: popupModel.count > 0

      WlrLayershell.namespace: "omarchy-notifications"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      // Full-screen, fixed-size surface (like the OSD overlay). Adding or
      // removing a toast changes only the content inside; the Wayland surface
      // never resizes, so the compositor can't briefly scale a stale buffer --
      // which is what stretched/squished the cards during count changes.
      anchors { top: true; bottom: true; left: true; right: true }

      // Keep the surface click-through except over the toast column, so the
      // rest of the (invisible) full-screen overlay never eats input.
      mask: Region { item: popupColumn }

      // ---- Merged-shape open/close state ----
      // One continuous OLED blob now holds every current toast as a "row"
      // (see the Repeater below), rather than each toast drawing its own
      // separate rounded card. openProgress is the container-level counterpart
      // of the old per-card dripProgress: 0 = fully collapsed to a flush-
      // corner nub (nothing on screen), 1 = fully open at the shape's real
      // width. It only moves on the very first toast appearing (nub -> full
      // width) and the very last one leaving (full width -> nub) -- adding or
      // removing a row while the shape is already open never touches it, only
      // the shape's HEIGHT changes then (see popupColumn.height below, which
      // each row drives directly via its own growProgress).
      property real openProgress: 0

      NumberAnimation {
        id: openAnim
        target: popupWindow
        property: "openProgress"
        to: 1
        duration: 420
        easing.type: Easing.OutBack
        easing.overshoot: 1.3
      }

      NumberAnimation {
        id: closeAnim
        target: popupWindow
        property: "openProgress"
        to: 0
        duration: 220
        easing.type: Easing.InOutCubic
      }

      // Called by a row's Component.onCompleted. A no-op once already fully
      // open (or opening) so a 2nd/3rd toast arriving doesn't yank
      // openProgress back to 0 and re-run the nub pop for no reason -- only
      // the row itself grows in that case. Reverses an in-flight close (a
      // fresh toast arriving while the last one is mid-exit) smoothly from
      // wherever openProgress currently sits, since neither animation sets an
      // explicit `from`.
      function openMergedShape() {
        if (popupWindow.openProgress >= 0.999 && !closeAnim.running) return
        closeAnim.stop()
        openAnim.restart()
      }

      // Called by a row's beginExit() only when it is the LAST remaining
      // popup, so the whole shape shrinks back into its nub in lockstep with
      // that row's own fade -- not on every dismissal, which would wrongly
      // collapse the shared shape while sibling rows are still on screen.
      function closeMergedShape() {
        openAnim.stop()
        closeAnim.restart()
      }

      // Pitch-black backdrop for every current toast row, drawn ONCE behind
      // the whole column rather than once per card -- this is what makes
      // multiple toasts read as a single continuous "OLED blob" instead of a
      // stack of separate pills with gaps between them. Geometry always
      // matches popupColumn exactly (same x/y/width/height), and it repaints
      // whenever that geometry changes -- which happens continuously while
      // rows grow/shrink, since popupColumn's real height is just the live
      // sum of its children's (animated) implicitHeight.
      Canvas {
        id: mergedShape
        z: -1
        x: popupColumn.x
        y: popupColumn.y
        width: popupColumn.width
        height: popupColumn.height

        property real op: popupWindow.openProgress
        onOpChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var w = width
          var h = height
          if (w <= 0 || h <= 0) return

          // Width only ever moves during the open/close transition (see
          // openProgress above); height tracks the column's real, live
          // height directly -- each row's own grow/shrink animation already
          // smooths it, so no separate easing is applied to it here (doing
          // so would double-ease and make the shape wobble oddly whenever a
          // row is added to or removed from an already-open stack).
          var opClamped = Math.max(0, Math.min(1, popupWindow.openProgress))
          var minNub = Math.min(24, w)
          var curW = minNub + (w - minNub) * opClamped
          var curH = Math.max(minNub, h)

          var finalR = Math.max(0, service.cornerRadius)
          var capsuleR = Math.min(curW, curH) / 2
          var freeR = capsuleR + (finalR - capsuleR) * Math.pow(opClamped, 2.2)
          freeR = Math.max(0, Math.min(freeR, curW / 2, curH / 2))

          var corner = service.popupCorner
          var top = 0
          var bottom = curH
          var left, right
          if (corner === "center") {
            var cx = w / 2
            left = cx - curW / 2
            right = cx + curW / 2
          } else if (corner === "left") {
            left = 0
            right = curW
          } else {
            right = w
            left = right - curW
          }

          // The corner(s) touching the true top edge (and, for left/right,
          // the true side edge too) stay perfectly sharp for as long as the
          // shape is on screen -- that flush point is what reads as "grown
          // from the corner" instead of "a shape that happens to be nearby
          // it." Every other corner uses freeR.
          var rTL = 0, rTR = 0, rBL = freeR, rBR = freeR
          if (corner === "right") { rTL = freeR; rTR = 0 }
          else if (corner === "left") { rTL = 0; rTR = freeR }
          // "center" leaves both top corners flush with the top edge -- a
          // flat-topped tab, like the shape is hanging from the edge itself
          // rather than touching a corner point.

          ctx.fillStyle = "#000000"
          ctx.beginPath()
          ctx.moveTo(left + rTL, top)
          ctx.lineTo(right - rTR, top)
          ctx.arcTo(right, top, right, top + rTR, rTR)
          ctx.lineTo(right, bottom - rBR)
          ctx.arcTo(right, bottom, right - rBR, bottom, rBR)
          ctx.lineTo(left + rBL, bottom)
          ctx.arcTo(left, bottom, left, bottom - rBL, rBL)
          ctx.lineTo(left, top + rTL)
          ctx.arcTo(left, top, left + rTL, top, rTL)
          ctx.closePath()
          ctx.fill()
        }
      }

      ColumnLayout {
        id: popupColumn
        anchors.top: parent.top
        // Flush against the TRUE physical top edge -- zero margin. This
        // renders on the Overlay layer, above a top/left/right bar, by
        // design: any margin here (even a small Style.gapsOut one, tried
        // previously) still reads as "floating near the corner" rather than
        // "in the actual corner" per live feedback with screenshots, twice.
        anchors.topMargin: 0
        // Horizontal position is driven by service.popupCorner (left/center/
        // right, user-configurable -- see Service.setPopupCorner) rather
        // than a fixed anchors.right, so the whole stack -- and the merged
        // shape's flush growth corner above -- can move to any edge. Flush
        // against that side's true physical edge too, for the same reason
        // as the top margin: zero, not Style.gapsOut.
        // ColumnLayout doesn't bind its own width to implicitWidth when it
        // isn't filling its parent on both sides, so that's set explicitly.
        width: implicitWidth
        x: {
          if (service.popupCorner === "left") return 0
          if (service.popupCorner === "center") return Math.round((popupWindow.width - width) / 2)
          return popupWindow.width - width
        }
        // No inter-row spacing: rows now merge into one shape, separated by
        // a hairline divider drawn inside each row rather than a gap between
        // independent cards (see the Repeater delegate below).
        spacing: 0

        Repeater {
          model: popupModel

          // The delegate is a ROW inside the one shared, merged shape drawn
          // by mergedShape above -- not an independent card anymore. It
          // still owns everything per-toast that always lived here (lifetime
          // timer, hover-pause, dismiss/expire/invoke, content-refresh reset)
          // -- only the VISUAL container changed from "one canvas + one card
          // per delegate" to "one canvas for the whole column, one
          // transparent content row per delegate." Newest toast is index 0
          // (top of the column, nearest the flush corner); every row below
          // it draws a hairline divider against the one above.
          delegate: Item {
            id: cardSlot
            required property int index
            required property string app
            required property string appIcon
            required property string summary
            required property string body
            required property string image
            required property string glyph
            required property int urgency
            required property double expireTimeout
            required property double timestamp

            // A divider above every row except the topmost -- it separates
            // this row from its neighbor instead of a gap between separate
            // cards, so multiple toasts read as rows in one blob.
            readonly property real dividerHeight: cardSlot.index > 0 ? Style.hairline : 0
            readonly property real fullContentHeight: cardSlot.dividerHeight + card.implicitHeight

            Layout.preferredWidth: card.implicitWidth
            implicitWidth: card.implicitWidth
            // The row's real (Layout-visible) height is what actually drives
            // the merged shape's height -- see mergedShape's `height:
            // popupColumn.height` binding above. Growing/shrinking THIS,
            // rather than leaving it constant and only faking the shrink
            // visually (the old single-card design's trick), is what makes
            // the shared shape smoothly grow/shrink around a row being added
            // or removed while siblings stay put, instead of holding size
            // until the row disappears and then snapping.
            implicitHeight: cardSlot.fullContentHeight * cardSlot.growProgress
            // Reveals the row (divider + card) from the top down as it
            // grows, and crops it the same way on the way out, rather than
            // letting the fixed-size content poke out past its own
            // currently-animated slot height.
            clip: true

            readonly property real lifetime: service.durationFor(cardSlot.urgency, cardSlot.expireTimeout)
            property real remainingLifetime: 1.0
            readonly property bool ticking: cardSlot.lifetime > 0 && !card.hovered && !cardSlot.exiting

            // ---- per-row entrance/exit state ----
            // growProgress: 0 = collapsed to nothing (no height at all), 1 =
            // fully grown and settled. This is the per-row counterpart of
            // popupWindow.openProgress above -- that one nub-grows the
            // SHARED shape's width on the very first/last toast; this one
            // grows THIS row's height, every time, whether it's the first
            // toast opening the whole shape or the third one slotting into
            // an already-open one.
            property real growProgress: 0
            property bool exiting: false
            property string pendingAction: "dismiss"

            Component.onCompleted: {
              rowEnterAnim.start()
              // No-op if the shape is already open -- only actually pops the
              // nub open for the first toast; every later one just grows its
              // own row into the already-full-width shape.
              popupWindow.openMergedShape()
            }

            // Same fast, slightly springy expand as the shape's own open
            // animation (see popupWindow.openAnim) -- a quick grow that
            // slightly overshoots and settles inside ~420ms, long enough to
            // be genuinely visible frame-to-frame rather than front-loaded.
            NumberAnimation {
              id: rowEnterAnim
              target: cardSlot
              property: "growProgress"
              from: 0
              to: 1
              duration: 420
              easing.type: Easing.OutBack
              easing.overshoot: 1.3
            }

            // Contracting is a plain, un-springy ease -- the reverse of the
            // grow, not a bounce on the way in.
            NumberAnimation {
              id: rowExitAnim
              target: cardSlot
              property: "growProgress"
              to: 0
              duration: 220
              easing.type: Easing.InOutCubic
              onFinished: {
                if (cardSlot.pendingAction === "invoke") service.invokePopupDefault(cardSlot.index)
                else if (cardSlot.pendingAction === "expire") service.expirePopup(cardSlot.index)
                else service.dismissPopup(cardSlot.index)
              }
            }

            // Starts the retract animation; the actual model removal (which
            // still does everything removePopup always did -- archiving,
            // liveRefs dismiss/expire, etc.) only runs once it finishes.
            // cardSlot.index stays live-bound by the Repeater while this
            // delegate exists, exactly as the countdown Timer below already
            // relied on for its much longer expiry delay.
            function beginExit(action) {
              if (cardSlot.exiting) return
              cardSlot.exiting = true
              cardSlot.pendingAction = action
              // Only shrink the SHARED shape's width back to a nub when this
              // is the last row standing -- otherwise sibling rows are still
              // showing and the shape must stay fully open, just shorter.
              if (popupModel.count === 1) popupWindow.closeMergedShape()
              rowExitAnim.start()
            }

            // A client updating this notification in place rewrites the row
            // under the card (see refreshPopup). New text deserves a full look,
            // so the countdown starts over instead of running out the clock the
            // superseded text was already most of the way through. Delegates
            // keep their own row as the model changes around them, so only a
            // real content change lands here.
            onSummaryChanged: cardSlot.remainingLifetime = 1.0
            onBodyChanged: cardSlot.remainingLifetime = 1.0
            onImageChanged: cardSlot.remainingLifetime = 1.0

            Timer {
              interval: 50
              repeat: true
              running: cardSlot.ticking
              onTriggered: {
                if (cardSlot.lifetime <= 0) return
                cardSlot.remainingLifetime -= 50.0 / cardSlot.lifetime
                if (cardSlot.remainingLifetime <= 0) {
                  cardSlot.remainingLifetime = 0
                  cardSlot.beginExit("expire")
                }
              }
            }

            // Content (icon/text, and the divider below) only fades and pops
            // in once the row is mostly at full height, so nothing looks
            // stretched while still growing -- same formula on the way out,
            // so content is already gone well before the row shrinks small
            // enough to look cramped. Mirrors the old single-card settleP.
            readonly property real settleP: Math.max(0, Math.min(1, (cardSlot.growProgress - 0.55) / 0.45))

            // Hairline separator from the row above. Purely decorative --
            // subtle low-opacity white against the pitch-black shared shape,
            // never a bright element competing with the text -- and it
            // fades with this row's own grow/shrink so it never lingers as
            // an orphaned line when a neighbor is removed or a new one
            // slots in above it (which is also why its own presence isn't
            // separately animated when `index` itself changes -- it just
            // rides whichever row it belongs to).
            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: Style.hairline
              color: "#FFFFFF"
              opacity: cardSlot.index > 0 ? cardSlot.settleP * 0.14 : 0
              visible: cardSlot.index > 0
            }

            NotificationCard {
              id: card
              // cardSlot.Layout.preferredWidth is always exactly
              // card.implicitWidth, so this never actually has room to
              // shift -- kept simple (not corner-aware) rather than risking
              // an "undefined" anchor assignment for no visible effect.
              anchors.top: parent.top
              anchors.topMargin: cardSlot.dividerHeight
              anchors.right: parent.right
              app: cardSlot.app
              appIcon: cardSlot.appIcon
              summary: cardSlot.summary
              body: cardSlot.body
              image: cardSlot.image
              urgency: cardSlot.urgency
              timestamp: cardSlot.timestamp
              cornerRadius: service.cornerRadius
              fontFamily: service.shell && service.shell.bar ? service.shell.bar.fontFamily : ""
              glyph: cardSlot.glyph
              // Popup-only: pitch-black text/icon palette, independent of
              // the active theme. The history panel never sets this.
              popupMode: true
              // This row paints no background/border/radius/clip of its
              // own -- mergedShape (above) is the one continuous shape
              // behind every row, so a per-row surface here would draw a
              // second, redundant rounded box under the text and defeat the
              // whole point of merging. The history panel never sets this
              // either, so its independent per-entry card rendering (its
              // own black-ish/themed rounded box) is untouched.
              flatMode: true

              opacity: cardSlot.settleP
              scale: 0.92 + 0.08 * cardSlot.settleP

              onCloseRequested: cardSlot.beginExit("dismiss")
              onCardClicked: cardSlot.beginExit("invoke")
            }
          }
        }
      }
    }
  }
}
