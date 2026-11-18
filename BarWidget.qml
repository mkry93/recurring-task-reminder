pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.mkry93.task-reminders"

  property bool panelOpen: false
  property bool statePrepared: false
  property bool stateReady: false
  property bool stateError: false
  property var tasks: []
  property double clockNow: Date.now()
  property var notifyQueue: []
  property var notifyInFlight: null
  property string draftMode: "days"
  property var draftDays: []
  property int draftMonthDay: 1
  property int draftHour: 9
  property int draftMinute: 0
  property int draftRepeatMinutes: 0
  readonly property string stateFilePath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/recurring-task-reminder/tasks.json"
  readonly property int dueCount: tasks.filter(function(task) { return Number(task.dueAt) <= root.clockNow }).length

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function parseState(raw) {
    try {
      var parsed = JSON.parse(raw || "{\"version\":1,\"tasks\":[]}")
      if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.tasks) || parsed.tasks.length > 500)
        throw new Error("Unsupported task reminder state")
      for (var i = 0; i < parsed.tasks.length; i++) {
        var task = parsed.tasks[i]
        if (!task || typeof task.id !== "string" || typeof task.title !== "string"
            || !["days", "weekly", "monthly"].includes(task.mode)
            || !Array.isArray(task.days) || !Number.isFinite(Number(task.dueAt))
            || !Number.isFinite(Number(task.hour)) || task.hour < 0 || task.hour > 23
            || !Number.isFinite(Number(task.minute)) || task.minute < 0 || task.minute > 59
            || !Number.isFinite(Number(task.monthDay)) || task.monthDay < 1 || task.monthDay > 31
            || !Number.isFinite(Number(task.repeatMinutes)) || task.repeatMinutes < 0 || task.repeatMinutes > 10080
            || !Number.isFinite(Number(task.lastNotifiedAt)) || task.id.length > 100
            || task.title.length === 0 || task.title.length > 120
            || (task.mode === "days" && task.days.length === 0)
            || (task.mode === "weekly" && task.days.length !== 1)
            || task.days.some(function(day) { return !Number.isInteger(day) || day < 0 || day > 6 }))
          throw new Error("Invalid task reminder entry")
      }
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

  function createTask(titleValue, timeValue, repeatValue, monthDayValue) {
    if (!stateReady || stateError) return
    var title = String(titleValue).trim()
    var time = String(timeValue).trim().match(/^(\d{1,2}):(\d{2})$/)
    if (!title || title.length > 120 || !time || Number(time[1]) > 23 || Number(time[2]) > 59) {
      formError.text = strings.t("error.titleTime")
      return
    }
    if ((draftMode === "days" && draftDays.length === 0) || (draftMode === "weekly" && draftDays.length !== 1)) {
      formError.text = draftMode === "weekly" ? strings.t("error.weekday") : strings.t("error.days")
      return
    }
    var repeat = Number(repeatValue || 0)
    var monthDay = Number(monthDayValue || 0)
    if (!Number.isInteger(repeat) || repeat < 0 || repeat > 10080
        || (draftMode === "monthly" && (!Number.isInteger(monthDay) || monthDay < 1 || monthDay > 31))) {
      formError.text = strings.t("error.repeatMonth")
      return
    }
    var task = {
      id: Date.now().toString(36) + Math.random().toString(36).slice(2),
      title: title,
      mode: draftMode,
      days: draftDays.slice().sort(function(a, b) { return a - b }),
      monthDay: monthDay,
      hour: Number(time[1]),
      minute: Number(time[2]),
      repeatMinutes: repeat,
      dueAt: 0,
      lastNotifiedAt: 0
    }
    task.dueAt = nextDate(task, Date.now())
    if (!task.dueAt) {
      formError.text = strings.t("error.nextDate")
      return
    }
    tasks = tasks.concat([task])
    formError.text = ""
    titleInput.text = ""
    saveState()
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
    onPressed: root.panelOpen = !root.panelOpen
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
      blocked: titleInput.activeFocus || timeInput.activeFocus || repeatInput.activeFocus || monthDayInput.activeFocus
      onCloseRequested: root.panelOpen = false

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: strings.t("plugin.title")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            visible: root.stateError
            textFormat: Text.PlainText
            text: strings.t("state.unavailable")
            color: Commons.Color.bar.urgent
            wrapMode: Text.Wrap
            width: parent.width
          }

          Repeater {
            model: root.tasks
            delegate: BorderSurface {
              required property var modelData
              width: contentColumn.width
              implicitHeight: taskRow.implicitHeight + Style.space(16)
              color: "transparent"
              borderSpec: Border.controlSpec("normal", Commons.Color.popups.text, Commons.Color.accent)

              Row {
                id: taskRow
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(8)

                Column {
                  width: parent.width - doneButton.width - deleteButton.width - parent.spacing * 2
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
                  iconText: "\uf2ed"
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

          Rectangle { width: parent.width; height: Style.space(1); color: Commons.Color.popups.border }

          Text {
            textFormat: Text.PlainText
            text: strings.t("task.add")
            color: Commons.Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

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
                { value: "weekly", label: strings.t("schedule.weekly") },
                { value: "monthly", label: strings.t("schedule.monthly") }
              ]
              onChanged: function(next) { root.draftMode = next; root.draftDays = [] }
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
            visible: root.draftMode !== "monthly"
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
                readonly property bool chosen: root.draftDays.indexOf(index) >= 0
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
                  enabled: root.draftMode !== "weekly" || root.draftDays.indexOf(index) < 0 || root.draftDays.length === 1
                  onClicked: {
                    var selected = root.draftDays.slice()
                    if (selected.indexOf(index) >= 0) selected.splice(selected.indexOf(index), 1)
                    else if (root.draftMode === "weekly") selected = [index]
                    else selected.push(index)
                    root.draftDays = selected
                  }
                }
              }
            }
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
            id: formError
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            color: Commons.Color.bar.urgent
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          PanelActionButton {
            width: parent.width
            size: Style.spacing.controlHeight
            iconText: "\uf067"
              tooltipText: strings.t("task.add")
            foreground: Commons.Color.popups.text
            enabled: root.stateReady && !root.stateError
            bordered: true
            onClicked: root.createTask(titleInput.text, timeInput.text, repeatInput.text, monthDayInput.text)
          }
        }
      }
    }
  }
}
