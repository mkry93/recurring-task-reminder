pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.mkry93.task-reminders"

  property bool panelOpen: false
  property string viewMode: "list"
  property bool statePrepared: false
  property bool stateReady: false
  property bool stateError: false
  property var tasks: []
  property double clockNow: Date.now()
  property var notifyQueue: []
  property var notifyInFlight: null
  property string draftMode: "days"
  property var draftDays: []
  property int draftWeeklyDay: -1
  property string formErrorText: ""
  property string editingTaskId: ""
  property string transferMode: ""
  property string importPath: ""
  property string exportPath: ""
  property string transferMessage: ""
  property string transferPayload: ""
  property bool exportStarted: false
  readonly property string stateFilePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/recurring-task-reminder/tasks.json"
  readonly property int dueCount: tasks.filter(function(task) { return Number(task.dueAt) <= root.clockNow }).length

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function validateTaskList(items) {
    if (!Array.isArray(items) || items.length > 500) return "invalid task list size"
    var ids = ({})
    for (var i = 0; i < items.length; i++) {
      var task = items[i]
      if (!task || typeof task.id !== "string" || task.id.length === 0 || task.id.length > 100 || ids[task.id]
          || typeof task.title !== "string" || task.title.length === 0 || task.title.length > 120
          || !["once", "days", "interval", "weekly", "monthly"].includes(task.mode)
          || !Array.isArray(task.days) || task.days.length > 7
          || !Number.isInteger(Number(task.dueAt)) || task.dueAt <= 0 || task.dueAt > 8640000000000000
          || !Number.isInteger(task.hour) || task.hour < 0 || task.hour > 23
          || !Number.isInteger(task.minute) || task.minute < 0 || task.minute > 59
          || !Number.isInteger(task.monthDay) || (task.mode === "monthly" && (task.monthDay < 1 || task.monthDay > 31))
          || !Number.isInteger(task.repeatMinutes) || task.repeatMinutes < 0 || task.repeatMinutes > 10080
          || !Number.isFinite(Number(task.lastNotifiedAt)) || task.lastNotifiedAt < 0
          || (task.mode === "days" && task.days.length === 0)
          || (task.mode === "weekly" && task.days.length !== 1)
          || (task.mode === "interval" && (!Number.isInteger(task.intervalDays) || task.intervalDays < 1 || task.intervalDays > 3650))
          || task.days.some(function(day) { return !Number.isInteger(day) || day < 0 || day > 6 }))
        return "invalid task entry"
      for (var d = 0; d < task.days.length; d++) {
        if (task.days.indexOf(task.days[d]) !== d) return "duplicate weekday"
      }
      ids[task.id] = true
      if (task.mode === "interval" || task.mode === "once") {
        if (!task.startDate) task.startDate = dateInput(new Date(task.dueAt))
        if (!parseStartDate(task.startDate)) return "invalid start date"
      }
    }
    return ""
  }

  function parseState(raw) {
    try {
      var parsed = JSON.parse(raw || "{\"version\":1,\"tasks\":[]}")
      if (!parsed || parsed.version !== 1)
        throw new Error("Unsupported task reminder state")
      var issue = validateTaskList(parsed.tasks)
      if (issue) throw new Error(issue)
      tasks = parsed.tasks
      stateReady = true
      stateError = false
      checkDueTasks()
    } catch (error) {
      console.warn("Recurring Tasks: saved data could not be read: " + error)
      stateError = true
    }
  }

  function saveState() {
    if (!stateReady || stateError) return
    stateFile.setText(JSON.stringify({ version: 1, tasks: tasks }, null, 2) + "\n")
  }

  function nextDate(task, afterMs) {
    var after = new Date(afterMs)
    if (task.mode === "interval") {
      var intervalDate = new Date(after.getFullYear(), after.getMonth(), after.getDate() + Number(task.intervalDays),
        Number(task.hour), Number(task.minute), 0, 0)
      return intervalDate.getTime() > afterMs ? intervalDate.getTime() : 0
    }
    var date = new Date(after.getFullYear(), after.getMonth(), after.getDate())
    for (var offset = 0; offset <= 370; offset++) {
      var candidateDate = new Date(date.getFullYear(), date.getMonth(), date.getDate() + offset)
      var matches = false
      if (task.mode === "monthly") {
        matches = candidateDate.getDate() === Number(task.monthDay)
      } else {
        var weekday = candidateDate.getDay()
        matches = task.mode === "weekly"
          ? weekday === Number(task.days[0])
          : task.days.indexOf(weekday) >= 0
      }
      if (!matches) continue
      var candidate = new Date(candidateDate.getFullYear(), candidateDate.getMonth(), candidateDate.getDate(),
        Number(task.hour), Number(task.minute), 0, 0)
      if (candidate.getTime() > afterMs) return candidate.getTime()
    }
    return 0
  }

  function parseStartDate(value) {
    var parts = String(value || "").match(/^(\d{2})\/(\d{2})\/(\d{4})$/)
    if (!parts) return null
    var day = Number(parts[1]), month = Number(parts[2]), year = Number(parts[3])
    if (year < 1900 || year > 9999) return null
    var parsed = new Date(year, month - 1, day)
    return parsed.getFullYear() === year && parsed.getMonth() === month - 1 && parsed.getDate() === day
      ? parsed : null
  }

  function dateInput(date) {
    return String(date.getDate()).padStart(2, "0") + "/"
      + String(date.getMonth() + 1).padStart(2, "0") + "/"
      + String(date.getFullYear()).padStart(4, "0")
  }

  function currentDateInput() {
    return dateInput(new Date())
  }

  function firstIntervalDate(startDate, intervalDays, hour, minute, nowMs) {
    var anchor = parseStartDate(startDate)
    if (!anchor) return 0
    var now = new Date(nowMs)
    var dayDifference = Math.floor((Date.UTC(now.getFullYear(), now.getMonth(), now.getDate())
      - Date.UTC(anchor.getFullYear(), anchor.getMonth(), anchor.getDate())) / 86400000)
    var occurrence = Math.max(0, Math.floor(dayDifference / intervalDays))
    var candidate = new Date(anchor.getFullYear(), anchor.getMonth(), anchor.getDate() + occurrence * intervalDays,
      hour, minute, 0, 0)
    if (candidate.getTime() < Math.floor(nowMs / 60000) * 60000) {
      occurrence++
      candidate = new Date(anchor.getFullYear(), anchor.getMonth(), anchor.getDate() + occurrence * intervalDays,
        hour, minute, 0, 0)
    }
    return candidate.getTime()
  }

  function timeLabel(date) {
    return date.getHours()
      + ":" + (date.getMinutes() < 10 ? "0" : "") + date.getMinutes()
  }

  function nextDueLabel(ms) {
    if (ms <= clockNow) return strings.t("task.now")
    var next = new Date(ms)
    var now = new Date(clockNow)
    var days = Math.round((Date.UTC(next.getFullYear(), next.getMonth(), next.getDate())
      - Date.UTC(now.getFullYear(), now.getMonth(), now.getDate())) / 86400000)
    var formattedDate = next.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "dd/MM/yy")
    var formattedTime = timeLabel(next)
    if (days === 0) return strings.t("task.todayAt").arg(formattedTime)
    return strings.tn("task.nextIn", days)
      .arg(Commons.I18n.formatNumber(days)).arg(formattedDate).arg(formattedTime)
  }

  function checkDueTasks() {
    if (!stateReady || stateError) return
    var now = Date.now()
    for (var i = 0; i < tasks.length; i++) {
      var task = tasks[i]
      if (Number(task.dueAt) > now) continue
      var repeatMs = Number(task.repeatMinutes) * 60000
      if (Number(task.lastNotifiedAt) === 0 || (repeatMs > 0 && now - Number(task.lastNotifiedAt) >= repeatMs)) {
        if (!notificationPending(task.id, Number(task.dueAt)))
          notifyQueue.push({ id: task.id, dueAt: Number(task.dueAt) })
      }
    }
    startNextNotification()
  }

  function notificationPending(id, dueAt) {
    if (notifyInFlight !== null && notifyInFlight.id === id && notifyInFlight.dueAt === dueAt) return true
    return notifyQueue.some(function(item) { return item.id === id && item.dueAt === dueAt })
  }

  function startNextNotification() {
    if (notifyInFlight !== null) return
    while (notifyQueue.length > 0) {
      var next = notifyQueue.shift()
      var task = null
      for (var i = 0; i < tasks.length; i++) {
        if (tasks[i].id === next.id && Number(tasks[i].dueAt) === next.dueAt) { task = tasks[i]; break }
      }
      if (task !== null) { notifyInFlight = { id: next.id, dueAt: next.dueAt, title: task.title }; break }
    }
    if (notifyInFlight === null) return
    var safeTitle = String(notifyInFlight.title).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    notification.command = ["omarchy-notification-send", strings.t("notification.headline"), safeTitle]
    notification.running = true
  }

  function finishTask(id) {
    if (!stateReady || stateError) return
    var next = []
    for (var i = 0; i < tasks.length; i++) {
      var task = tasks[i]
      if (task.id !== id) { next.push(task); continue }
      if (task.mode === "once") continue
      var dueAt = nextDate(task, Number(task.dueAt))
      if (dueAt > 0) {
        task.dueAt = dueAt
        task.lastNotifiedAt = 0
        next.push(task)
      }
    }
    tasks = next
    saveState()
    checkDueTasks()
  }

  function deleteTask(id) {
    if (!stateReady || stateError) return
    tasks = tasks.filter(function(task) { return task.id !== id })
    saveState()
  }

  function createTask(titleValue, timeValue, repeatValue, monthDayValue, intervalValue, startDateValue) {
    if (!stateReady || stateError) return false
    var title = String(titleValue).trim()
    var time = String(timeValue).trim().match(/^(\d{1,2}):(\d{2})$/)
    if (!title || title.length > 120 || !time || Number(time[1]) > 23 || Number(time[2]) > 59) {
      formErrorText = strings.t("error.titleTime")
      return false
    }
    if ((draftMode === "days" && draftDays.length === 0) || (draftMode === "weekly" && draftWeeklyDay < 0)) {
      formErrorText = draftMode === "weekly" ? strings.t("error.weekday") : strings.t("error.days")
      return false
    }
    var repeat = Number(repeatValue || 0)
    var monthDay = Number(monthDayValue || 0)
    var intervalDays = Number(intervalValue || 0)
    var intervalStart = draftMode === "interval" || draftMode === "once" ? parseStartDate(startDateValue) : null
    var originalTask = null
    if (editingTaskId) {
      for (var i = 0; i < tasks.length; i++) {
        if (tasks[i].id === editingTaskId) { originalTask = tasks[i]; break }
      }
      if (!originalTask) return false
    }
    if (!Number.isInteger(repeat) || repeat < 0 || repeat > 10080
        || (draftMode === "monthly" && (!Number.isInteger(monthDay) || monthDay < 1 || monthDay > 31))
        || ((draftMode === "interval" || draftMode === "once") && !intervalStart)
        || (draftMode === "interval" && (!Number.isInteger(intervalDays) || intervalDays < 1 || intervalDays > 3650))) {
      formErrorText = strings.t("error.schedule")
      return false
    }
    var task = {
      id: editingTaskId || Date.now().toString(36) + Math.random().toString(36).slice(2),
      title: title,
      mode: draftMode,
      days: (draftMode === "weekly" ? [draftWeeklyDay] : draftDays.slice()).sort(function(a, b) { return a - b }),
      monthDay: monthDay,
      intervalDays: intervalDays,
      startDate: intervalStart ? dateInput(intervalStart) : "",
      hour: Number(time[1]),
      minute: Number(time[2]),
      repeatMinutes: repeat,
      dueAt: 0,
      lastNotifiedAt: 0
    }
    var sameSchedule = originalTask !== null && originalTask.mode === task.mode
      && JSON.stringify(originalTask.days) === JSON.stringify(task.days)
      && Number(originalTask.monthDay) === task.monthDay
      && Number(originalTask.intervalDays) === task.intervalDays
      && originalTask.startDate === task.startDate
      && Number(originalTask.hour) === task.hour && Number(originalTask.minute) === task.minute
    if (sameSchedule)
      task.dueAt = Number(originalTask.dueAt)
    else if (draftMode === "interval")
      task.dueAt = firstIntervalDate(startDateValue, intervalDays, task.hour, task.minute, Date.now())
    else if (draftMode === "once")
      task.dueAt = new Date(intervalStart.getFullYear(), intervalStart.getMonth(), intervalStart.getDate(), task.hour, task.minute).getTime()
    else
      task.dueAt = nextDate(task, Date.now())
    if (!task.dueAt) {
      formErrorText = strings.t("error.nextDate")
      return false
    }
    if (sameSchedule && Number(originalTask.repeatMinutes) === task.repeatMinutes)
      task.lastNotifiedAt = Number(originalTask.lastNotifiedAt)
    if (editingTaskId) {
      var updated = false
      tasks = tasks.map(function(existing) {
        if (existing.id !== editingTaskId) return existing
        updated = true
        return task
      })
      if (!updated) return false
      editingTaskId = ""
    } else {
      tasks = tasks.concat([task])
    }
    formErrorText = ""
    saveState()
    checkDueTasks()
    return true
  }

  function exportTasks(fileUrl) {
    if (!stateReady || stateError || transferMode !== "") return
    var exported = tasks.map(function(task) {
      return {
        id: task.id,
        title: task.title,
        mode: task.mode,
        days: task.days,
        monthDay: task.monthDay,
        intervalDays: task.intervalDays,
        startDate: task.startDate,
        hour: task.hour,
        minute: task.minute,
        repeatMinutes: task.repeatMinutes,
        dueDate: dateInput(new Date(Number(task.dueAt))),
        dueAt: task.dueAt,
        lastNotifiedAt: task.lastNotifiedAt
      }
    })
    var payload = JSON.stringify({ format: "omarchy-recurring-task-reminders", version: 1, tasks: exported }, null, 2) + "\n"
    if (payload.length > 1048576) {
      transferMessage = strings.t("transfer.tooLarge")
      return
    }
    transferMode = "export"
    transferMessage = ""
    exportStarted = false
    transferPayload = payload
    exportPath = String(fileUrl)
  }

  function writeExport() {
    if (transferMode !== "export" || exportStarted) return
    exportStarted = true
    exportFile.setText(transferPayload)
  }

  function importFromFile(fileUrl) {
    if (!stateReady || stateError || transferMode !== "") return
    transferMessage = ""
    transferMode = "import"
    importPath = String(fileUrl)
  }

  function importTasks(raw) {
    if (!stateReady || stateError || raw.length > 1048576) {
      transferMessage = strings.t("transfer.tooLarge")
      transferMode = ""
      importPath = ""
      return
    }
    try {
      var imported = JSON.parse(raw)
      if (!imported || imported.format !== "omarchy-recurring-task-reminders" || imported.version !== 1)
        throw new Error("unsupported file")
      var issue = validateTaskList(imported.tasks)
      if (issue) throw new Error(issue)
      for (var v = 0; v < imported.tasks.length; v++) {
        if (imported.tasks[v].dueDate !== undefined && !parseStartDate(imported.tasks[v].dueDate))
          throw new Error("invalid due date")
      }
      var existing = ({})
      for (var i = 0; i < tasks.length; i++) existing[tasks[i].id] = true
      var additions = []
      for (var j = 0; j < imported.tasks.length; j++) {
        var source = imported.tasks[j]
        if (existing[source.id]) continue
        existing[source.id] = true
        var portableDueDate = source.dueDate ? parseStartDate(source.dueDate) : null
        additions.push({
          id: source.id,
          title: source.title,
          mode: source.mode,
          days: source.days.slice(),
          monthDay: source.monthDay,
          intervalDays: source.intervalDays,
          startDate: source.startDate || "",
          hour: source.hour,
          minute: source.minute,
          repeatMinutes: source.repeatMinutes,
          dueAt: portableDueDate
            ? new Date(portableDueDate.getFullYear(), portableDueDate.getMonth(), portableDueDate.getDate(), source.hour, source.minute).getTime()
            : source.dueAt,
          lastNotifiedAt: 0
        })
      }
      if (tasks.length + additions.length > 500) throw new Error("too many tasks")
      tasks = tasks.concat(additions)
      saveState()
      checkDueTasks()
      transferMessage = additions.length
        ? strings.tn("transfer.imported", additions.length).arg(Commons.I18n.formatNumber(additions.length))
        : strings.t("transfer.noNewTasks")
    } catch (error) {
      transferMessage = strings.t("transfer.invalid")
      console.warn("Recurring Tasks import: " + error)
    }
    transferMode = ""
    importPath = ""
  }

  function editTask(task) {
    editingTaskId = task.id
    draftMode = task.mode
    draftDays = task.days.slice()
    draftWeeklyDay = task.mode === "weekly" ? Number(task.days[0]) : -1
    formErrorText = ""
    titleInput.text = task.title
    timeInput.text = String(task.hour).padStart(2, "0") + ":" + String(task.minute).padStart(2, "0")
    repeatInput.text = String(task.repeatMinutes)
    monthDayInput.text = String(task.monthDay)
    intervalInput.text = String(task.intervalDays)
    startDateInput.text = task.startDate || dateInput(new Date(Number(task.dueAt)))
    viewMode = "add"
  }

  function scheduleType(task) {
    if (task.mode === "once") return strings.t("schedule.once")
    if (task.mode === "interval") return strings.tn("task.type.interval", Number(task.intervalDays)).arg(Commons.I18n.formatNumber(task.intervalDays))
    if (task.mode === "weekly") return strings.t("schedule.weekly")
    if (task.mode === "monthly") return strings.t("task.type.monthly").arg(Commons.I18n.formatNumber(task.monthDay))
    return strings.t("schedule.days")
  }

  function open() { viewMode = "list"; panelOpen = true }
  function close() { panelOpen = false }
  function togglePanel() { panelOpen ? close() : open() }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  function formatDue(ms) {
    var due = new Date(ms)
    return due.toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), { weekday: "short", month: "short", day: "numeric" })
      + " · " + (due.getHours() < 10 ? "0" : "") + due.getHours()
      + ":" + (due.getMinutes() < 10 ? "0" : "") + due.getMinutes()
  }

  Process {
    id: prepareState
    command: ["bash", "-c", "umask 077; mkdir -p -- \"$1\" && chmod 700 -- \"$1\" && touch -- \"$2\"", "task-reminders", root.stateFilePath.substring(0, root.stateFilePath.lastIndexOf("/")), root.stateFilePath]
    onExited: function(code) {
      if (code === 0) { root.statePrepared = true; stateFile.reload() }
      else { root.stateError = true; console.warn("Recurring Tasks: could not prepare state storage") }
    }
  }

  FileView {
    id: stateFile
    path: root.statePrepared ? root.stateFilePath : ""
    atomicWrites: true
    printErrors: false
    onLoaded: root.parseState(text())
    onLoadFailed: { root.stateError = true; console.warn("Recurring Tasks: could not load saved tasks") }
    onSaveFailed: { root.stateError = true; console.warn("Recurring Tasks: could not save tasks; editing paused to protect saved data") }
  }

  FileView {
    id: importFile
    path: root.importPath
    atomicWrites: true
    printErrors: false
    onLoaded: if (root.transferMode === "import") root.importTasks(text())
    onLoadFailed: {
      if (root.transferMode === "import") {
        root.transferMessage = strings.t("transfer.readFailed")
        root.transferMode = ""
        root.importPath = ""
      }
    }
  }

  FileView {
    id: exportFile
    path: root.exportPath
    atomicWrites: true
    printErrors: false
    onLoaded: if (root.transferMode === "export") root.writeExport()
    onLoadFailed: if (root.transferMode === "export") root.writeExport()
    onSaved: {
      if (root.transferMode !== "export") return
      root.transferMessage = strings.t("transfer.exported")
      root.transferMode = ""
      root.exportPath = ""
      root.transferPayload = ""
    }
    onSaveFailed: {
      if (root.transferMode !== "export") return
      root.transferMessage = strings.t("transfer.writeFailed")
      root.transferMode = ""
      root.exportPath = ""
      root.transferPayload = ""
    }
  }

  FileDialog {
    id: exportDialog
    title: strings.t("transfer.exportTitle")
    fileMode: FileDialog.SaveFile
    defaultSuffix: "json"
    nameFilters: [strings.t("transfer.filter")]
    onAccepted: root.exportTasks(selectedFile)
  }

  FileDialog {
    id: importDialog
    title: strings.t("transfer.importTitle")
    fileMode: FileDialog.OpenFile
    nameFilters: [strings.t("transfer.filter")]
    onAccepted: root.importFromFile(selectedFile)
  }

  Process {
    id: notification
    onExited: function(code) {
      var sent = root.notifyInFlight
      root.notifyInFlight = null
      if (sent !== null && code === 0) {
        for (var i = 0; i < root.tasks.length; i++) {
          if (root.tasks[i].id === sent.id && Number(root.tasks[i].dueAt) === sent.dueAt)
            root.tasks[i].lastNotifiedAt = Date.now()
        }
        root.tasks = root.tasks.slice()
        root.saveState()
      } else if (code !== 0) {
        console.warn("Recurring Tasks: notification failed; it will be retried")
      }
      root.startNextNotification()
    }
  }

  Component.onCompleted: { prepareState.running = true }
  Timer {
    interval: 15000
    repeat: true
    running: root.stateReady && !root.stateError
    triggeredOnStart: true
    onTriggered: { root.clockNow = Date.now(); root.checkDueTasks() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontSize: 15
    text: "\u{f0ae}"
    active: root.panelOpen
    tooltipText: root.dueCount > 0
      ? strings.tn("bar.due", root.dueCount).arg(Commons.I18n.formatNumber(root.dueCount))
      : strings.t("plugin.title")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.panelOpen
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(450))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(680))

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: contentColumn.implicitHeight
      blocked: titleInput.activeFocus || timeInput.activeFocus || repeatInput.activeFocus || monthDayInput.activeFocus || intervalInput.activeFocus || startDateInput.activeFocus
      onCloseRequested: root.close()

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width - (root.viewMode === "list" ? addButton.width + importButton.width + exportButton.width + parent.spacing * 3 : backButton.width) - parent.spacing
              textFormat: Text.PlainText
              text: strings.t(root.viewMode === "list" ? "plugin.title" : (root.editingTaskId ? "task.edit" : "task.add"))
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }
            PanelActionButton {
              id: addButton
              visible: root.viewMode === "list"
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf067"
              tooltipText: strings.t("task.add")
              foreground: Commons.Color.popups.text
              focusable: true
              bordered: true
              onClicked: {
                root.formErrorText = ""
                root.editingTaskId = ""
                titleInput.text = ""
                startDateInput.text = root.currentDateInput()
                root.viewMode = "add"
              }
            }
            PanelActionButton {
              id: importButton
              visible: root.viewMode === "list"
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf019"
              tooltipText: strings.t("transfer.import")
              foreground: Commons.Color.popups.text
              focusable: true
              bordered: true
              enabled: root.stateReady && !root.stateError && root.transferMode === ""
              onClicked: importDialog.open()
            }
            PanelActionButton {
              id: exportButton
              visible: root.viewMode === "list"
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf093"
              tooltipText: strings.t("transfer.export")
              foreground: Commons.Color.popups.text
              focusable: true
              bordered: true
              enabled: root.stateReady && !root.stateError && root.transferMode === ""
              onClicked: exportDialog.open()
            }
            PanelActionButton {
              id: backButton
              visible: root.viewMode === "add"
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf060"
              tooltipText: strings.t("nav.tasks")
              foreground: Commons.Color.popups.text
              focusable: true
              bordered: true
              onClicked: { root.editingTaskId = ""; root.viewMode = "list" }
            }
          }

          Text {
            visible: root.stateError
            textFormat: Text.PlainText
            text: strings.t("state.unavailable")
            color: Commons.Color.bar.urgent
            wrapMode: Text.Wrap
            width: parent.width
          }

          Text {
            visible: root.viewMode === "list" && root.transferMessage !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.transferMessage
            color: Commons.Color.popups.text
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            id: listPage
            visible: root.viewMode === "list"
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.tasks
              delegate: BorderSurface {
                required property var modelData
                width: listPage.width
                implicitHeight: taskRow.implicitHeight + Style.space(16)
                color: Commons.Color.popups.background
                borderSpec: Border.controlSpec("normal", Commons.Color.popups.text, Commons.Color.accent)

                Row {
                  id: taskRow
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)

                  Column {
                    width: parent.width - editButton.width - doneButton.width - deleteButton.width - parent.spacing * 3
                    spacing: Style.space(3)
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: modelData.title
                      color: Commons.Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: root.formatDue(Number(modelData.dueAt)) + (Number(modelData.dueAt) <= root.clockNow ? " · " + strings.t("task.dueSuffix") : "")
                      color: Number(modelData.dueAt) <= root.clockNow ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.2)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: root.scheduleType(modelData)
                      color: Qt.darker(Commons.Color.popups.text, 1.2)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: root.nextDueLabel(Number(modelData.dueAt))
                      color: Number(modelData.dueAt) <= root.clockNow ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.2)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                  PanelActionButton {
                    id: editButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "\uf044"
                    tooltipText: strings.t("task.edit")
                    foreground: Commons.Color.popups.text
                    enabled: !root.stateError
                    onClicked: root.editTask(modelData)
                  }
                  PanelActionButton {
                    id: doneButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "\uf00c"
                    tooltipText: strings.t("task.done")
                    foreground: Commons.Color.popups.text
                    enabled: !root.stateError
                    onClicked: root.finishTask(modelData.id)
                  }
                  PanelActionButton {
                    id: deleteButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "×"
                    tooltipText: strings.t("task.delete")
                    foreground: Commons.Color.popups.text
                    enabled: !root.stateError
                    onClicked: root.deleteTask(modelData.id)
                  }
                }
              }
            }

            Text {
              visible: root.tasks.length === 0 && !root.stateError
              textFormat: Text.PlainText
              text: strings.t("task.empty")
              color: Qt.darker(Commons.Color.popups.text, 1.2)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          Column {
            id: editorPage
            visible: root.viewMode === "add"
            width: parent.width
            spacing: Style.space(10)

            TextField {
              id: titleInput
              width: parent.width
              placeholderText: strings.t("task.name")
              enabled: root.stateReady && !root.stateError
              maximumLength: 120
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Dropdown {
                width: (parent.width - parent.spacing) * 0.58
                label: strings.t("schedule.repeat")
                value: root.draftMode
                options: [
                  { value: "days", label: strings.t("schedule.days") },
                  { value: "interval", label: strings.t("schedule.interval") },
                  { value: "weekly", label: strings.t("schedule.weekly") },
                  { value: "monthly", label: strings.t("schedule.monthly") },
                  { value: "once", label: strings.t("schedule.once") }
                ]
                onChanged: function(next) {
                  root.draftMode = next
                  if (next === "weekly" && root.draftWeeklyDay < 0 && root.draftDays.length > 0)
                    root.draftWeeklyDay = root.draftDays[0]
                }
              }
              TextField {
                id: timeInput
                width: parent.width - parent.children[0].width - parent.spacing
                placeholderText: strings.t("time.placeholder")
                text: "09:00"
                maximumLength: 5
              }
            }

            Row {
              visible: root.draftMode === "days" || root.draftMode === "weekly"
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: [strings.t("weekday.sun"), strings.t("weekday.mon"), strings.t("weekday.tue"),
                  strings.t("weekday.wed"), strings.t("weekday.thu"), strings.t("weekday.fri"), strings.t("weekday.sat")]
                delegate: BorderSurface {
                  required property int index
                  required property string modelData
                  width: (parent.width - parent.spacing * 6) / 7
                  height: Style.space(32)
                  readonly property bool chosen: root.draftMode === "weekly"
                    ? root.draftWeeklyDay === index
                    : root.draftDays.indexOf(index) >= 0
                  color: chosen ? Style.hoverFillFor(Commons.Color.popups.text, Commons.Color.accent) : "transparent"
                  borderSpec: Border.controlSpec(chosen ? "focus" : "normal", Commons.Color.popups.text, Commons.Color.accent)
                  Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData
                    color: Commons.Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: {
                      if (root.draftMode === "weekly") root.draftWeeklyDay = index
                      else {
                        var selected = root.draftDays.slice()
                        if (selected.indexOf(index) >= 0) selected.splice(selected.indexOf(index), 1)
                        else selected.push(index)
                        root.draftDays = selected
                      }
                    }
                  }
                }
              }
            }

            Row {
              visible: root.draftMode === "interval"
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width * 0.62
                textFormat: Text.PlainText
                text: strings.t("schedule.intervalDays")
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              TextField {
                id: intervalInput
                width: parent.width - parent.children[0].width - parent.spacing
                placeholderText: "1"
                text: "9"
                maximumLength: 4
                validator: IntValidator { bottom: 1; top: 3650 }
              }
            }

            TextField {
              id: startDateInput
              visible: root.draftMode === "interval" || root.draftMode === "once"
              width: parent.width
              placeholderText: strings.t(root.draftMode === "once" ? "schedule.onceDate" : "schedule.startDate")
              text: root.currentDateInput()
              maximumLength: 10
            }

            TextField {
              id: monthDayInput
              visible: root.draftMode === "monthly"
              width: parent.width
              placeholderText: strings.t("schedule.monthDay")
              text: "1"
              maximumLength: 2
              validator: IntValidator { bottom: 1; top: 31 }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width * 0.57
                textFormat: Text.PlainText
                text: strings.t("schedule.repeatMinutes")
                wrapMode: Text.Wrap
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              TextField {
                id: repeatInput
                width: parent.width - parent.children[0].width - parent.spacing
                placeholderText: "0"
                text: "0"
                maximumLength: 5
                validator: IntValidator { bottom: 0; top: 10080 }
              }
            }

            Text {
              visible: root.formErrorText !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.formErrorText
              color: Commons.Color.bar.urgent
              wrapMode: Text.Wrap
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            PanelActionButton {
              width: parent.width
              size: Style.spacing.controlHeight
              iconText: "\uf00c"
              tooltipText: strings.t(root.editingTaskId ? "task.update" : "task.save")
              foreground: Commons.Color.popups.text
              enabled: root.stateReady && !root.stateError
              bordered: true
              onClicked: {
                if (root.createTask(titleInput.text, timeInput.text, repeatInput.text, monthDayInput.text, intervalInput.text, startDateInput.text)) {
                  titleInput.text = ""
                  root.viewMode = "list"
                }
              }
            }
          }
        }
      }
    }
  }
}
