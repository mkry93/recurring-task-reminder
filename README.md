# Recurring Tasks

A small Omarchy bar plugin for recurring reminders that stay due until you mark
them done. It supports selected weekdays, every N days, a weekly weekday, and
a day of each month. Every N days takes a start date in `DD/MM/YYYY` form and
keeps that date as its recurrence anchor. Tasks use local time; monthly dates
that do not exist in a month are skipped.
One-time reminders use a chosen date and time. A reminder that became due while
the laptop or shell was off is delivered when the shell next opens, even if
several days passed. Repeated reminders continue until marked done.

The popup separates the task list from task creation. Choose **Add task** to
open the form; save or return to the list when done.

If the shell resumes after a due time, the reminder is delivered on its next
15-second check. Optional repeated reminders continue at the chosen minute
interval until the task is marked done. Missed later occurrences are caught up
one at a time after the current occurrence is completed.

Task data is stored under
`$XDG_STATE_HOME/omarchy/recurring-task-reminder/tasks.json` (or
`~/.local/state/omarchy/recurring-task-reminder/tasks.json`).
Use the import and export buttons to move tasks as versioned JSON. Imports merge
tasks and skip matching IDs. Due dates are saved as local calendar dates, so
moving the file between time zones keeps the date and scheduled local time.

Install in the Omarchy user plugin directory, then enable with
`omarchy plugin enable io.github.mkry93.task-reminders --section right`.
