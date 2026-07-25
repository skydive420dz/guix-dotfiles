;;; sk-notes.el --- Personal note workflow -*- lexical-binding: t; -*-

(require 'org)
(require 'org-archive)
(require 'org-capture)
(require 'sk-window-policy)
(require 'subr-x)

(defvar sk/org-notes-root (expand-file-name "~/Documents/OrgFiles/")
  "Root directory for personal Org notes.")

(defconst sk/org-daily-note-template
  "#+title: {{date}} - {{weekday}}
#+date: {{date}}
#+startup: overview
#+category: daily
#+filetags: :daily:

* Plan

** Focus
- …

** Today
- …

** If there is extra time
- …

* Inbox

Use this section for quick notes that should be sorted later.

* Log

* Notes

* Review

** Wins
- …

** Friction
- …

** Carry forward
- …
"
  "Complete fallback document for newly-created daily notes.")

(defconst sk/org-weekly-note-template
  "#+title: {{week}}
#+date: {{date}}
#+startup: overview
#+category: weekly
#+filetags: :weekly:

* Review

** What moved
- …

** What stalled
- …

** What kept showing up
- …

* Decisions

- …

* Next Week

** Focus
- …

** Commitments
- …

** Carry forward
- …

* Notes
"
  "Complete fallback document for newly-created weekly notes.")

(defconst sk/org-workflow-help-text
  "Org workflow

From EXWM application buffers in line mode
  C-c j     Capture
  C-c n i   Open the Inbox for clarification
  C-c n a   Open the agenda
  C-c n r   Run the daily review
  C-c n W   Run the weekly review
  C-c n h   Show this help

Inside Emacs
  SPC n c   Capture
  SPC n i   Open the Inbox for clarification
  SPC n a   Open the agenda
  SPC n d   Run the daily review
  SPC n w   Run the weekly review
  SPC n h   Show this help

Clarify and finish
  Process each Inbox item into a task, project, topic, note, or archive.
  In an Org buffer, use SPC m r to refile the current item.
  DONE items stay where they are.  SPC m A archives only when requested,
  into the central Archive.org file.
"
  "Concise help for the personal Org workflow.")

(defun sk/org-agenda-note-files ()
  "Return every Org note file under `sk/org-notes-root'."
  (let ((templates-dir (expand-file-name "Templates/" sk/org-notes-root))
        (archive-file (sk/org-archive-file)))
    (when (file-directory-p sk/org-notes-root)
      (delq nil
            (mapcar (lambda (file)
                      (unless (or (file-in-directory-p file templates-dir)
                                  (string-equal (expand-file-name file)
                                                archive-file))
                        file))
                    (directory-files-recursively sk/org-notes-root "\\.org\\'"))))))

(defun sk/org-refresh-agenda-files ()
  "Refresh `org-agenda-files' from the note tree."
  (interactive)
  (setq org-agenda-files (or (sk/org-agenda-note-files) nil))
  (when (called-interactively-p 'interactive)
    (message "Org agenda files refreshed: %d" (length org-agenda-files))))

(defun sk/org--slugify (text)
  "Return a simple filename slug for TEXT."
  (let* ((downcased (downcase text))
         (clean (replace-regexp-in-string "[^[:alnum:]]+" "-" downcased)))
    (string-trim clean "-" "-")))

(defun sk/org--read-file-as-string (file)
  "Return FILE contents as a string when FILE is readable."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun sk/org--template (file fallback replacements)
  "Read FILE or FALLBACK, then apply REPLACEMENTS."
  (let ((template (or (sk/org--read-file-as-string file) fallback)))
    (dolist (replacement replacements template)
      (setq template
            (replace-regexp-in-string
             (car replacement)
             (cdr replacement)
             template t t)))))

(defun sk/org--ensure-document (file contents)
  "Create FILE with complete document CONTENTS when it does not exist."
  (make-directory (file-name-directory file) t)
  (unless (file-exists-p file)
    (with-temp-file file
      (insert contents)
      (unless (bolp)
        (insert "\n")))
    (when (boundp 'org-agenda-files)
      (sk/org-refresh-agenda-files)))
  file)

(defun sk/org--ensure-file (file title &optional body)
  "Create FILE with TITLE and optional BODY when it does not exist."
  (sk/org--ensure-document
   file
   (concat "#+title: " title "\n"
           "#+date: " (format-time-string "%Y-%m-%d") "\n"
           "#+startup: overview\n\n"
           body)))

(defun sk/org--ensure-heading (file heading)
  "Open FILE for capture and return point below HEADING, creating it if needed."
  (set-buffer (org-capture-target-buffer file))
  (goto-char (point-min))
  (unless (re-search-forward
           (format org-complex-heading-regexp-format (regexp-quote heading))
           nil t)
    (goto-char (point-max))
    (unless (bolp)
      (insert "\n"))
    (insert "\n* " heading "\n"))
  (org-end-of-subtree t t)
  (unless (bolp)
    (insert "\n"))
  (point))

(defun sk/org-inbox-file ()
  "Return the personal inbox file, creating it if needed."
  (sk/org--ensure-file
   (expand-file-name "Inbox.org" sk/org-notes-root)
   "Inbox"
   "* Inbox\n"))

(defun sk/org-archive-file ()
  "Return the central archive file."
  (expand-file-name "Archive.org" sk/org-notes-root))

(defun sk/org-central-archive-location ()
  "Return the Org location for source-grouped central archiving."
  (concat (sk/org-archive-file) "::* From %s"))

(defun sk/org-tasks-file ()
  "Return the task file, creating it if needed."
  (sk/org--ensure-file
   (expand-file-name "Tasks.org" sk/org-notes-root)
   "Tasks"
   "* Inbox\n"))

(defun sk/org-journal-file ()
  "Return the journal file, creating it if needed."
  (sk/org--ensure-file
   (expand-file-name "Journal.org" sk/org-notes-root)
   "Journal"))

(defun sk/org-metrics-file ()
  "Return the metrics file, creating it if needed."
  (sk/org--ensure-file
   (expand-file-name "Metrics.org" sk/org-notes-root)
   "Metrics"
   "* Weight\n| Date | Weight | Notes |\n|-\n"))

(defun sk/org-daily-file (&optional time)
  "Return a daily note file for TIME, creating it if needed."
  (let* ((time (or time (current-time)))
         (date (format-time-string "%Y-%m-%d" time))
         (weekday (format-time-string "%A" time))
         (template-file (expand-file-name "Templates/Daily.org" sk/org-notes-root))
         (body (sk/org--template
                template-file
                sk/org-daily-note-template
                `(("{{date}}" . ,date)
                  ("{{weekday}}" . ,weekday))))
         (file (expand-file-name (concat "Daily/" date ".org") sk/org-notes-root)))
    (sk/org--ensure-document file body)))

(defun sk/org-weekly-file (&optional time)
  "Return a weekly note file for TIME, creating it if needed."
  (let* ((time (or time (current-time)))
         (week (format-time-string "%G-W%V" time))
         (date (format-time-string "%Y-%m-%d" time))
         (template-file (expand-file-name "Templates/Weekly.org" sk/org-notes-root))
         (body (sk/org--template
                template-file
                sk/org-weekly-note-template
                `(("{{week}}" . ,week)
                  ("{{date}}" . ,date))))
         (file (expand-file-name (concat "Weekly/" week ".org") sk/org-notes-root)))
    (sk/org--ensure-document file body)))

(defun sk/org-topic-file ()
  "Prompt for a topic note and return its file path, creating it if needed."
  (let* ((year (format-time-string "%Y"))
         (title (read-string "Topic: "))
         (slug (sk/org--slugify title))
         (date (format-time-string "%Y-%m-%d"))
         (file (expand-file-name (concat "Topics/" year "/" date "-" slug ".org") sk/org-notes-root)))
    (sk/org--ensure-file file title "* Notes\n")))

(defun sk/org-project-file ()
  "Prompt for a project note and return its file path, creating it if needed."
  (let* ((name (read-string "Project: "))
         (slug (sk/org--slugify name))
         (file (expand-file-name (concat "Projects/" slug ".org") sk/org-notes-root)))
    (sk/org--ensure-file
     file
     name
     "* Overview\n* Tasks\n* Notes\n* Decisions\n* Follow-up\n")))

(defun sk/org-open-daily-note ()
  "Open today's daily note."
  (interactive)
  (find-file (sk/org-daily-file)))

(defun sk/org-open-weekly-note ()
  "Open this week's note."
  (interactive)
  (find-file (sk/org-weekly-file)))

(defun sk/org-open-inbox ()
  "Open the personal inbox."
  (interactive)
  (find-file (sk/org-inbox-file)))

(defun sk/org-clarify-inbox ()
  "Open and reveal the canonical Inbox for deliberate processing."
  (interactive)
  (find-file (sk/org-inbox-file))
  (goto-char (point-min))
  (when (re-search-forward
         (format org-complex-heading-regexp-format "Inbox")
         nil t)
    (org-back-to-heading t)
    (org-show-subtree)
    (org-end-of-meta-data t))
  (message
   "Clarify each item, then use SPC m r to refile or SPC m A to archive it."))

(defun sk/org-open-topic-note ()
  "Create or open a topic note."
  (interactive)
  (find-file (sk/org-topic-file)))

(defun sk/org-open-project-note ()
  "Create or open a project note."
  (interactive)
  (find-file (sk/org-project-file)))

(defun sk/org-open-notes-root ()
  "Open the personal notes root in Dired."
  (interactive)
  (dired sk/org-notes-root))

(defun sk/org-find-note ()
  "Find a note under `sk/org-notes-root'."
  (interactive)
  (let ((default-directory sk/org-notes-root))
    (if (fboundp 'counsel-find-file)
        (call-interactively #'counsel-find-file)
      (call-interactively #'find-file))))

(defun sk/org-search-notes ()
  "Search the personal notes tree."
  (interactive)
  (if (fboundp 'counsel-rg)
      (counsel-rg nil sk/org-notes-root)
    (rgrep (read-string "Search notes: ")
           "*.org"
           sk/org-notes-root)))

(defun sk/org-agenda ()
  "Refresh note discovery, then open Org agenda."
  (interactive)
  (sk/org-refresh-agenda-files)
  (call-interactively #'org-agenda))

(defun sk/org-todo-agenda ()
  "Refresh note discovery, then open the Org TODO agenda."
  (interactive)
  (sk/org-refresh-agenda-files)
  (org-agenda nil "t"))

(defun sk/org--review (note-file agenda-key)
  "Open NOTE-FILE and show AGENDA-KEY through the shared window policy."
  (sk/org-refresh-agenda-files)
  (find-file note-file)
  (let* ((note-window (selected-window))
         (agenda-buffer
          (save-window-excursion
            (org-agenda nil agenda-key)
            (current-buffer))))
    (sk/window-display-right agenda-buffer)
    (when (window-live-p note-window)
      (select-window note-window))))

(defun sk/org-daily-review ()
  "Open today's note and the daily agenda dashboard."
  (interactive)
  (sk/org--review (sk/org-daily-file) "d"))

(defun sk/org-weekly-review ()
  "Open this week's note and the weekly agenda dashboard."
  (interactive)
  (sk/org--review (sk/org-weekly-file) "w"))

(defun sk/org-workflow-help ()
  "Show the concise personal Org workflow."
  (interactive)
  (with-help-window "*Org Workflow*"
    (princ sk/org-workflow-help-text)))

(defun sk/org-daily-capture-target ()
  "Return a capture target inside today's daily Inbox."
  (sk/org--ensure-heading (sk/org-daily-file) "Inbox"))

(defun sk/org-inbox-capture-target ()
  "Return a capture target inside the inbox note."
  (sk/org--ensure-heading (sk/org-inbox-file) "Inbox"))

(defun sk/org-task-capture-target ()
  "Return a capture target inside the task inbox."
  (sk/org--ensure-heading (sk/org-tasks-file) "Inbox"))

(defun sk/org-metrics-weight-target ()
  "Return a capture target inside the weight metrics table."
  (let ((file (sk/org-metrics-file)))
    (sk/org--ensure-heading file "Weight")
    (unless (save-excursion
              (forward-line -1)
              (org-at-table-p))
      (insert "| Date | Weight | Notes |\n|-\n"))
    (while (and (not (eobp))
                (org-at-table-p))
      (forward-line 1))
    (unless (bolp)
      (insert "\n"))
    (point)))

(setq org-directory sk/org-notes-root
      org-agenda-files (or (sk/org-agenda-note-files) nil)
      ;; Batch validation must not create a personal inbox merely by loading
      ;; the configuration.  Interactive sessions retain the ensure-on-start
      ;; behavior used by capture commands.
      org-default-notes-file
      (if noninteractive
          (expand-file-name "Inbox.org" sk/org-notes-root)
        (sk/org-inbox-file))
      org-refile-targets '((org-agenda-files :maxlevel . 3))
      org-refile-use-outline-path 'file
      org-outline-path-complete-in-steps nil
      org-refile-allow-creating-parent-nodes 'confirm
      org-archive-location (sk/org-central-archive-location)
      org-archive-default-command 'org-archive-subtree
      org-archive-mark-done nil
      org-todo-keywords
      '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d!)")
        (sequence "BACKLOG(b)" "PLAN(p)" "READY(r)" "ACTIVE(a)" "REVIEW(v)" "WAIT(w@/!)" "HOLD(h)" "|" "COMPLETED(c)" "CANC(k@)"))
      org-tag-alist
      '((:startgroup)
        (:endgroup)
        ("@errand" . ?E)
        ("@home" . ?H)
        ("@work" . ?W)
        ("agenda" . ?a)
        ("planning" . ?p)
        ("publish" . ?P)
        ("batch" . ?b)
        ("note" . ?n)
        ("idea" . ?i)))

(setq org-agenda-custom-commands
      '(("d" "Daily review"
         ((agenda "" ((org-agenda-span 'day)
                      (org-deadline-warning-days 7)
                      (org-agenda-overriding-header "Today")))
          (todo "NEXT" ((org-agenda-overriding-header "Next tasks")))
          (todo "TODO" ((org-agenda-overriding-header "Open tasks")))
          (tags-todo "agenda/ACTIVE" ((org-agenda-overriding-header "Active projects")))))
        ("w" "Week"
         agenda ""
         ((org-agenda-span 'week)))
        ("i" "Inbox"
         tags "CATEGORY=\"Inbox\""
         ((org-agenda-overriding-header "Inbox")))
        ("f" "Follow-up"
         search "Follow-up"
         ((org-agenda-overriding-header "Follow-up")))
        ("n" "Next tasks"
         ((todo "NEXT"
                ((org-agenda-overriding-header "Next tasks")))))
        ("e" "Low effort tasks"
         tags-todo "+TODO=\"NEXT\"+Effort<15&+Effort>0"
         ((org-agenda-overriding-header "Low effort tasks")
          (org-agenda-max-todos 20)))
        ("s" "Workflow status"
         ((todo "WAIT" ((org-agenda-overriding-header "Waiting on external")))
          (todo "REVIEW" ((org-agenda-overriding-header "In review")))
          (todo "PLAN" ((org-agenda-overriding-header "In planning")
                        (org-agenda-todo-list-sublevels nil)))
          (todo "BACKLOG" ((org-agenda-overriding-header "Project backlog")
                           (org-agenda-todo-list-sublevels nil)))
          (todo "READY" ((org-agenda-overriding-header "Ready for work")))
          (todo "ACTIVE" ((org-agenda-overriding-header "Active projects")))
          (todo "COMPLETED" ((org-agenda-overriding-header "Completed projects")))
          (todo "CANC" ((org-agenda-overriding-header "Cancelled projects")))))))

(setq org-capture-templates
      '(("i" "Inbox note" entry
         (function sk/org-inbox-capture-target)
         "* %?\n  %U\n"
         :empty-lines 1)
        ("t" "Tasks / Projects")
        ("tt" "Task" entry
         (function sk/org-task-capture-target)
         "* TODO %?\n  %U\n  %a\n  %i"
         :empty-lines 1)
        ("d" "Daily inbox" entry
         (function sk/org-daily-capture-target)
         "* %?\n  %U\n"
         :empty-lines 1)
        ("T" "Topic note" entry
         (file+headline sk/org-topic-file "Notes")
         "* %?\n  %U\n"
         :empty-lines 1)
        ("p" "Project note" entry
         (file+headline sk/org-project-file "Notes")
         "* %?\n  %U\n"
         :empty-lines 1)
        ("j" "Journal entries")
        ("jj" "Journal" entry
         (file+olp+datetree sk/org-journal-file)
         "\n* %<%I:%M %p> - Journal :journal:\n\n%?\n\n"
         :clock-in :clock-resume
         :empty-lines 1)
        ("jm" "Meeting" entry
         (file+olp+datetree sk/org-journal-file)
         "* %<%I:%M %p> - %a :meetings:\n\n%?\n\n"
         :clock-in :clock-resume
         :empty-lines 1)
        ("w" "Workflows")
        ("we" "Checking email" entry
         (file+olp+datetree sk/org-journal-file)
         "* Checking email :email:\n\n%?"
         :clock-in :clock-resume
         :empty-lines 1)
        ("m" "Metrics capture")
        ("mw" "Weight" table-line
         (function sk/org-metrics-weight-target)
         "| %U | %^{Weight} | %^{Notes} |"
         :kill-buffer t)))

(global-set-key (kbd "C-c n i") #'sk/org-clarify-inbox)
(global-set-key (kbd "C-c n d") #'sk/org-open-daily-note)
(global-set-key (kbd "C-c n w") #'sk/org-open-weekly-note)
(global-set-key (kbd "C-c n W") #'sk/org-weekly-review)
(global-set-key (kbd "C-c n t") #'sk/org-open-topic-note)
(global-set-key (kbd "C-c n p") #'sk/org-open-project-note)
(global-set-key (kbd "C-c n o") #'sk/org-open-notes-root)
(global-set-key (kbd "C-c n f") #'sk/org-find-note)
(global-set-key (kbd "C-c n s") #'sk/org-search-notes)
(global-set-key (kbd "C-c n c") #'org-capture)
(global-set-key (kbd "C-c n a") #'sk/org-agenda)
(global-set-key (kbd "C-c n T") #'sk/org-todo-agenda)
(global-set-key (kbd "C-c n r") #'sk/org-daily-review)
(global-set-key (kbd "C-c n R") #'sk/org-refresh-agenda-files)
(global-set-key (kbd "C-c n h") #'sk/org-workflow-help)
(global-set-key (kbd "C-c j") #'org-capture)

(with-eval-after-load 'general
  (when (fboundp 'rune/leader-keys)
    (rune/leader-keys
      "n" '(:ignore t :which-key "notes")
      "ni" '(sk/org-clarify-inbox :which-key "inbox / clarify")
      "nd" '(sk/org-daily-review :which-key "daily review")
      "nw" '(sk/org-weekly-review :which-key "weekly review")
      "nh" '(sk/org-workflow-help :which-key "workflow help")
      "nt" '(sk/org-open-topic-note :which-key "topic note")
      "np" '(sk/org-open-project-note :which-key "project note")
      "no" '(sk/org-open-notes-root :which-key "notes root")
      "nf" '(sk/org-find-note :which-key "find note")
      "ns" '(sk/org-search-notes :which-key "search notes")
      "nc" '(org-capture :which-key "capture")
      "na" '(sk/org-agenda :which-key "agenda")
      "nT" '(sk/org-todo-agenda :which-key "todos")
      "nr" nil
      "nR" '(sk/org-refresh-agenda-files :which-key "refresh agenda"))))

(provide 'sk-notes)

;;; sk-notes.el ends here
