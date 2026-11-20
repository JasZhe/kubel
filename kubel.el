;;; kubel.el --- Control Kubernetes with limited permissions -*- lexical-binding: t; -*-

;; Copyright (C) 2018, Adrien Brochard

;; This file is NOT part of Emacs.

;; This  program is  free  software; you  can  redistribute it  and/or
;; modify it  under the  terms of  the GNU  General Public  License as
;; published by the Free Software  Foundation; either version 2 of the
;; License, or (at your option) any later version.



;; This program is distributed in the hope that it will be useful, but
;; WITHOUT  ANY  WARRANTY;  without   even  the  implied  warranty  of
;; MERCHANTABILITY or FITNESS  FOR A PARTICULAR PURPOSE.   See the GNU
;; General Public License for more details.

;; You should have  received a copy of the GNU  General Public License
;; along  with  this program;  if  not,  write  to the  Free  Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
;; USA

;; Version: 1.0
;; Author: Adrien Brochard
;; Keywords: kubernetes k8s tools processes
;; URL: https://github.com/abrochard/kubel
;; License: GNU General Public License >= 3
;; Package-Requires: ((transient "0.1.0") (emacs "25.3") (dash "2.12.0") (s "1.2.0") (yaml-mode "0.0.14"))

;;; Commentary:

;; Emacs extension for controlling Kubernetes with limited permissions.

;;; Usage:

;; To list the pods in your current context and namespace, call
;;
;; M-x kubel
;;
;; To set the path to the kubectl config file, call:
;; M-x kubel-set-kubectl-config-file
;;
;; or
;;
;; (kubel-set-kubectl-config-file <path to desired config file>)
;; ex: (kubel-set-kubectl-config-file "~/.kube/another-config")
;;
;; To set said namespace and context, respectively call
;;
;; M-x kubel-set-namespace
;; M-x kubel-set-context
;;
;; Note that namespace will autocomplete but not context,
;; this is because I interact with kubernetes through a user who
;; does not have permissions to list namespaces.
;;
;; To switch to showing a different resource, use the `R` command or
;;
;; M-x kubel-set-resource
;;
;; This will let you select a resource and re-display the kubel buffer.

;;; Shortcuts:

;; On the kubel screen, place your cursor on a resource
;;
;; enter => get resource details
;; C-u enter => describe resource
;; h => help popup
;; ? => help popup
;; E => quick edit any resource
;; g => refresh
;; C-c C-r => toggle automatic refresh
;; C-c C-a => toggle all namespaces
;; k => delete popup
;; r => see the rollout history for resource
;; p => port forward pod
;; l => log popup
;; e => exec popup
;; j => restart deployment
;; S => scale replicas
;; C => set context
;; n => set namespace
;; R => set resource
;; K => set kubectl config file
;; F => set output format
;; f => set a substring filter for resource name
;; M-n => jump to the next highlighted resource
;; M-p => jump to previous highlighted resource
;; m => mark item
;; u => unmark item
;; M => mark all items
;; U => unmark all items
;; c => copy popup
;; $ => show process buffer
;; s => show only resources with specified label value

;;; Customize:

;; By default, kubel log tails from the last 100 lines, you can change the `kubel-log-tail-n` variable to set another line number.

;;; Code:

(require 'transient)
(require 'dash)
(require 's)
(require 'yaml-mode)
(require 'tramp)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'eshell)
(require 'dired)
(require 'json)

(defgroup kubel nil "Customisation group for kubel."
  :group 'extensions)

(defconst kubel--list-sort-key
  '("NAME" . nil)
  "Sort table on this key.")

(defface kubel-status-running
  '((default . (:inherit success)))
  "The face to use for the Running status.")

(defface kubel-status-healthy
  '((default . (:inherit success)))
  "The face to use for the Healthy status.")

(defface kubel-status-active
  '((default . (:inherit success)))
  "The face to use for the Active status.")

(defface kubel-status-ready
  '((default . (:inherit success)))
  "The face to use for the Ready status.")

(defface kubel-status-true
  '((default . (:inherit success)))
  "The face to use for the True status.")

(defface kubel-status-unknown
  '((default . (:inherit warning)))
  "The face to use for the Unknown status.")

(defface kubel-status-error
  '((default . (:inherit error)))
  "The face to use for the Error status.")

(defface kubel-status-evicted
  '((default . (:inherit error)))
  "The face to use for the Evicted status.")

(defface kubel-status-memory-pressure
  '((default . (:inherit error)))
  "The face to use for the Memory Pressure status.")

(defface kubel-status-pid-pressure
  '((default . (:inherit error)))
  "The face to use for the PID Pressure status.")

(defface kubel-status-disk-pressure
  '((default . (:inherit error)))
  "The face to use for the Disk Pressure status.")

(defface kubel-status-revision-missing
  '((default . (:inherit error)))
  "The face to use for the Revision Missing status.")

(defface kubel-status-revision-failed
  '((default . (:inherit error)))
  "The face to use for the Revision Failed status.")

(defface kubel-status-network-unavailable
  '((default . (:inherit error)))
  "The face to use for the Network Unavailable status.")

(defface kubel-status-completed
  '((default . (:foreground "yellow")))
  "The face to use for the Completed status.")

(defface kubel-status-crash-loop-backoff
  '((default . (:inherit error)))
  "The face to use for the Crash Loop Backoff status.")

(defface kubel-status-terminating
  '((default . (:foreground "blue")))
  "The face to use for the Terminating status.")

(defcustom kubel-status-faces
  '(("Running" . kubel-status-running)
    ("Healthy" . kubel-status-healthy)
    ("Active" . kubel-status-active)
    ("Ready" . kubel-status-ready)
    ("True" . kubel-status-true)
    ("Unknown" . kubel-status-unknown)
    ("Error" . kubel-status-error)
    ("Evicted" . kubel-status-evicted)
    ("MemoryPressure" . kubel-status-memory-pressure)
    ("PIDPressure" . kubel-status-pid-pressure)
    ("DiskPressure" . kubel-status-disk-pressure)
    ("RevisionMissing" . kubel-status-revision-missing)
    ("RevisionFailed" . kubel-status-revision-failed)
    ("NetworkUnavailable" . kubel-status-network-unavailable)
    ("Completed" . kubel-status-completed)
    ("CrashLoopBackOff" . kubel-status-crash-loop-backoff)
    ("Terminating" . kubel-status-terminating))
  "Associative list of status to face."
  :type '(alist :key-type string
                :value-type face)
  :group 'kubel)

(defcustom kubel-kubectl "kubectl"
  "Kubectl binary path."
  :type '(file :must-match t)
  :group 'kubel)

(defconst kubel--process-buffer "*kubel-process*"
  "Kubel process buffer name.")

(defcustom kubel-output "yaml"
  "Format for output: json|yaml|wide|custom-columns=..."
  :type 'string
  :group 'kubel)

(defcustom kubel-log-tail-n 100
  "Default number of lines to tail."
  :type 'integer
  :group 'kubel)

(defcustom kubel-list-wide nil
  "Control whether list views show additional colums.

true   - use '-o wide' for list views to show additional columns
false  - do not use '-o wide' for list views, hiding additional columns"
  :type 'boolean
  :group 'kubel)


(defcustom kubel-use-namespace-list 'auto
  "Control behavior for namespace completion.

auto - check list permissions asynchronously and cache the result
on   - fetch namespace names asynchronously without a permission check
off  - use namespace history and defaults without fetching"
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "On" on)
                 (const :tag "Off" off))
  :group 'kubel)

(defcustom kubel-shell-buffer-name-format "kubel:%C:%n:%t:%c@%p"
  "Define the name format used for pod shell buffers.

This is a format string with %-sequences that will be substituted
with information about the shell's connection. The following
%-sequences are defined:

%t: The shell type. Examples of this are `shell` and `eshell`
%c: The container name
%p: The pod name
%n: The current namespace
%C: The current context"
  :type 'string
  :group 'kubel)

(defcustom kubel-kill-buffer-query t
  "Non-nil means that killing a modified resource buffer has to be confirmed.
This is used by `kubel-kill-buffer'."
  :type 'boolean
  :group 'kubel)

(defcustom kubel-default-namespace "default"
  "Default namespace for kubel to use. Change if you have no resources in
`default' namespace."
  :type 'string
  :group 'kubel)

(defun kubel--append-to-process-buffer (str)
  "Append string STR to the process buffer."
  (with-current-buffer (get-buffer-create kubel--process-buffer)
    (read-only-mode -1)
    (goto-char (point-max))
    (insert (format "%s\n" str))))

(defvar-local kubel--last-command nil)

(defvar-local kubel--header-error nil
  "Current error message to display, or nil if no error.")

(defvar-local kubel--error-overlay nil
  "Overlay used to display error message at top of buffer.")

(defun kubel--log-command (process-name cmd)
  "Log the kubectl command to the process buffer.

PROCESS-NAME is the name of the process.
CMD is the kubectl command as a list."
  (let ((str-cmd (if (equal 'string (type-of cmd)) cmd (mapconcat #'identity cmd " "))))
    (setq kubel--last-command str-cmd)
    (kubel--append-to-process-buffer
     (format "[%s]\ncommand: %s" process-name str-cmd))))

(defun kubel--set-header-error (error-msg)
  "Set ERROR-MSG as an overlay at the top of the buffer."
  (kubel--clear-header-error)
  (setq kubel--header-error error-msg)
  (when error-msg
    (let ((ov (make-overlay (point-min) (point-min))))
      (overlay-put ov 'before-string
                   (propertize (format "⚠ Kubel error: %s  [Type `$' for details]\n" error-msg)
                               'face 'error))
      (overlay-put ov 'kubel-error t)
      (setq kubel--error-overlay ov))))

(defun kubel--clear-header-error ()
  "Clear any error overlay from the buffer."
  (when kubel--error-overlay
    (delete-overlay kubel--error-overlay)
    (setq kubel--error-overlay nil))
  (setq kubel--header-error nil))

(defun kubel--handle-stderr (stderr-content)
  "Handle stderr output by logging to process buffer and displaying in header-line.
STDERR-CONTENT is the stderr string from a kubectl command."
  (when (and stderr-content (not (string-empty-p stderr-content)))
    (let ((trimmed (string-trim stderr-content)))
      (kubel--append-to-process-buffer (format "stderr: %s" trimmed))
      (kubel--set-header-error trimmed))))

(defun kubel--exec-sync (cmd &optional silence-warnings)
  "Run CMD synchronously and return output as string.
Logs to process buffer and displays any stderr via `kubel--handle-stderr'.
If SILENCE-WARNINGS is non-nil, stderr output is not displayed."
  (kubel--log-command "kubectl-command" cmd)
  (let ((stderr-buffer (generate-new-buffer " *kubel-stderr-temp*"))
        (result nil))
    (unwind-protect
        (progn
          (setq result
                (with-output-to-string
                  (with-current-buffer standard-output
                    (shell-command cmd t stderr-buffer))))
          (let ((stderr-output (with-current-buffer stderr-buffer (buffer-string))))
            (unless silence-warnings
              (kubel--handle-stderr stderr-output))))
      (kill-buffer stderr-buffer))
    result))

(defvar-local kubel-namespace kubel-default-namespace
  "Current namespace.")

(defvar-local kubel-all-namespaces nil
  "Non-nil to list resources across all namespaces.")

(defvar-local kubel-resource "pods"
  "Current resource.")

(defvar-local kubel-context nil
  "Current context.  Initialized lazily on first use.")

(defvar-local kubel-resource-filter ""
  "Substring filter for resource name.")

(defvar-local kubel-selector ""
  "Label selector for resources.")

(defvar kubel-namespace-history '()
  "List of previously used namespaces.")

(defvar kubel-selector-history '()
  "List of previously used selectors.")

(defvar-local kubel--label-values-cached nil)

(defvar-local kubel--selected-items '())

(defvar-local kubel--parent-buffer nil
  "The buffer that spawned this kubel buffer.
Used for back-navigation when pressing q.")

(defun kubel--invalidate-context-caches ()
  "Invalidate buffer-local context caches."
  (setq kubel--label-values-cached nil))

(defcustom kubel-spinner-frames '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Animation frames shown in the header and mode line while async commands run.
Use ASCII frames if your font lacks these glyphs."
  :type '(repeat string)
  :group 'kubel)

(defvar-local kubel--activity-processes nil
  "Async commands currently running for this buffer.")
(defvar-local kubel--activity-timer nil
  "Timer animating this buffer's activity indicator.")
(defvar-local kubel--activity-frame 0
  "Current animation frame.")
(defvar-local kubel--activity-saved-header nil
  "Header format to restore when this buffer's commands finish.")
(defconst kubel--activity-header-line '(:eval (kubel--activity-status))
  "Header format used while async commands are running.")

(defun kubel--activity-status ()
  "Return the header and mode-line activity indicator for this buffer."
  (when kubel--activity-processes
    (let ((count (length kubel--activity-processes)))
      (format " %s %s%s"
              (if (zerop (length kubel-spinner-frames)) "…"
                (elt kubel-spinner-frames
                     (mod kubel--activity-frame (length kubel-spinner-frames))))
              (replace-regexp-in-string
               "%" "%%" (truncate-string-to-width
                         (or (process-get (car kubel--activity-processes)
                                          'kubel-activity-label) "kubectl")
                         50 nil nil "…"))
              (if (> count 1) (format " (+%d)" (1- count)) "")))))

(add-to-list 'minor-mode-alist
             '(kubel--activity-processes (:eval (kubel--activity-status))))

(defun kubel--activity-clear ()
  "Stop this buffer's animation and clear its activity state."
  (when (timerp kubel--activity-timer)
    (cancel-timer kubel--activity-timer))
  (when (eq header-line-format kubel--activity-header-line)
    (setq header-line-format kubel--activity-saved-header))
  (setq kubel--activity-timer nil
        kubel--activity-processes nil
        kubel--activity-saved-header nil)
  (force-mode-line-update))

(defun kubel--activity-start (process buffers label)
  "Show PROCESS activity in BUFFERS, identified by LABEL."
  (process-put process 'kubel-activity-label label)
  (process-put process 'kubel-activity-buffers (delete-dups buffers))
  (dolist (buffer (process-get process 'kubel-activity-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless kubel--activity-processes
          (setq kubel--activity-saved-header header-line-format)
          (setq-local header-line-format kubel--activity-header-line))
        (push process kubel--activity-processes)
        (add-hook 'kill-buffer-hook #'kubel--activity-clear nil t)
        (add-hook 'change-major-mode-hook #'kubel--activity-clear nil t)
        (unless kubel--activity-timer
          (setq kubel--activity-frame 0
                kubel--activity-timer
                (run-at-time
                 0.2 0.2
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (setq kubel--activity-frame (1+ kubel--activity-frame))
                       (force-mode-line-update)))))))
        (force-mode-line-update)))))

(defun kubel--activity-stop (process)
  "Remove PROCESS from its buffers' activity indicators."
  (dolist (buffer (process-get process 'kubel-activity-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq kubel--activity-processes (delq process kubel--activity-processes))
        (unless kubel--activity-processes (kubel--activity-clear))
        (force-mode-line-update))))
  (process-put process 'kubel-activity-buffers nil))

(defvar-local kubel--refresh-process nil
  "Process fetching the current resource list or initial context.")

(defun kubel--cancel-refresh ()
  "Cancel any pending request for this buffer."
  (let ((process kubel--refresh-process))
    (setq kubel--refresh-process nil)
    (when (process-live-p process)
      (delete-process process))))

(defun kubel--request (command callback)
  "Run COMMAND asynchronously for this buffer.
Call CALLBACK with stdout on success.  Keep stderr separate from table data.
A newer request supersedes the pending request."
  (kubel--cancel-refresh)
  (kubel--stop-auto-refresh)
  (add-hook 'kill-buffer-hook #'kubel--cancel-refresh nil t)
  (kubel--log-command "kubel-refresh" command)
  (let ((origin (current-buffer))
        (stdout (generate-new-buffer " *kubel-refresh*"))
        (stderr (generate-new-buffer " *kubel-refresh-stderr*")))
    (condition-case err
        (progn
          (setq kubel--refresh-process
                (make-process
                 :name "kubel-refresh" :buffer stdout :stderr stderr
                 :command command :connection-type 'pipe :noquery t
                 :file-handler t
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (kubel--activity-stop process)
                     (unwind-protect
                         (when (buffer-live-p origin)
                           (with-current-buffer origin
                             (when (eq process kubel--refresh-process)
                               (setq kubel--refresh-process nil)
                               (let ((output (with-current-buffer stdout (buffer-string)))
                                     (errors (with-current-buffer stderr (buffer-string)))
                                     (status (process-exit-status process)))
                                 (kubel--append-to-process-buffer
                                  (format "[kubel-refresh]\nexit-code: %s" status))
                                 (if (and (eq (process-status process) 'exit)
                                          (zerop status))
                                     (progn
                                       (kubel--clear-header-error)
                                       (funcall callback output)
                                       (kubel--handle-stderr errors))
                                   (kubel--handle-stderr
                                    (if (string-empty-p (string-trim errors))
                                        (format "Command failed: %s" status)
                                      errors)))))))
                       (kill-buffer stdout)
                       (kill-buffer stderr)
                       (when (buffer-live-p origin)
                         (with-current-buffer origin
                           (kubel--schedule-auto-refresh))))))))
          (when (get-buffer-process stderr)
            (set-process-sentinel (get-buffer-process stderr) #'ignore)
            (set-process-query-on-exit-flag (get-buffer-process stderr) nil))
          (when (processp kubel--refresh-process)
            (kubel--activity-start kubel--refresh-process (list origin)
                                   (if kubel-context "Refreshing resources"
                                     "Loading context"))))
      (error
       (kill-buffer stdout)
       (kill-buffer stderr)
       (kubel--set-header-error (error-message-string err))
       (kubel--schedule-auto-refresh)))))

(defun kubel--render-list (body)
  "Update the current resource table from BODY."
  (let ((entrylist (kubel--parse-body body)))
    (setq tabulated-list-format (kubel--get-list-format entrylist))
    (setq tabulated-list-entries (kubel--get-list-entries entrylist)))
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header)
  (let ((line-num (line-number-at-pos (point)))
        (current-id (tabulated-list-get-id)))
    (tabulated-list-print t)
    (unless (equal current-id (tabulated-list-get-id))
      (goto-char (point-min))
      (forward-line (1- line-num))))
  (kubel--current-state))

(defun kubel--age-to-secs (age)
  "Convert AGE in format 1d2h3m4s to seconds."
  (let ((rex (rx bol
                 (opt (group (one-or-more digit)) "d")
                 (opt (group (one-or-more digit)) "h")
                 (opt (group (one-or-more digit)) "m")
                 (opt (group (one-or-more digit)) "s")
                 eol)))
    (if (string-match rex age)
        (-sum (--map-indexed
               (* (--if-let (match-string (1+ it-index) age)
                      (string-to-number it)
                    0)
                  it)
               '(86400 3600 60 1)))
      0)))

(defun kubel--make-age-comparator (colnum)
  "Return a function that compares two ages at given column COLNUM."
  (lambda (row1 row2)
    (let ((age1 (elt (cadr row1) colnum))
          (age2 (elt (cadr row2) colnum)))
      (< (kubel--age-to-secs age1)
         (kubel--age-to-secs age2)))))

(defun kubel--column-entry (entrylist)
  "Return a function of colnum to retrieve an entry in a given column for ENTRYLIST."
  (function
   (lambda (colnum)
     (let* ((name (kubel--column-header entrylist colnum))
            (width (+ 4 (kubel--column-width entrylist colnum)))
            (sort (if (member name '("AGE" "DURATION" "LAST SCHEDULE"))
                      (kubel--make-age-comparator colnum)
                    t)))
       (list name width sort)))))

(defun kubel--get-list-format (entrylist)
  "Get the list format.

ENTRYLIST is the output of the parsed body."
  (defun kubel--get-column-entry (colnum)
    (let ((kubel--get-entry (kubel--column-entry entrylist)))
      (funcall kubel--get-entry colnum)))
  (cl-map 'vector #'kubel--get-column-entry (number-sequence 0 (- (kubel--ncols entrylist) 1))))

(defun kubel--update-selected-items (entries)
  "Check that all selected items still exist.

ENTRIES are all resources."
  (dolist (i (-difference kubel--selected-items (mapcar #'car entries)))
    (setq kubel--selected-items (delete i kubel--selected-items))))

(defun kubel--get-list-entries (entrylist)
  "Build table entries from ENTRYLIST, including namespace in row identities."
  (let* ((namespaced (equal (caar entrylist) "NAMESPACE"))
         (entries
          (mapcar (lambda (row)
                    (list (if namespaced (cons (car row) (cadr row)) (car row))
                          (vconcat (mapcar #'kubel--propertize-status row))))
                  (cdr entrylist))))
    (kubel--update-selected-items entries)
    entries))

(defun kubel--parse-body (body)
  "Parse the body of kubectl get resource call into a list.

BODY is the raw output of kubectl get resource."
  (let* ((lines (or (nbutlast (split-string body "\n")) '("")))
         (header (car lines))
         ;; Cronjobs have a "LAST SCHEDULE" column, so need to split on 2+ whitespace chars.
         (starts (cl-loop for start = 0 then (match-end 0)
                          while (string-match (rx (>= 2 whitespace)) header start)
                          collect (match-end 0)))
         (position (-zip-with 'cons (cons 0 starts) (append starts '("end"))))
         (parse-line (lambda (line)
                       (mapcar (lambda (pos)
                                 (kubel--extract-value line (car pos) (cdr pos)))
                               position))))
    (mapcar parse-line lines)))

(defun kubel--extract-value (line min max)
  "Extract value from LINE between MIN and MAX.
If it's just white space, return -, else trim space.
If MAX is the end of the line, dynamically adjust."
  (let* ((maxx (if (equal max "end") (length line) max))
         (str (substring-no-properties line min maxx)))
    (if (string-match "^ +$" str)
        "-"
      (string-trim str))))

(defun kubel--ncols (entrylist)
  "Return the number of columns in ENTRYLIST."
  (length (car entrylist)))

(defun kubel--nrows (entrylist)
  "Return the nubmer of rows in ENTRYLIST."
  (length entrylist))

(defun kubel--column-header (entrylist colnum)
  "Return the header for a specific COLNUM in ENTRYLIST."
  (nth colnum (car entrylist)))

(defun kubel--column-width (entrylist colnum)
  "Return the width of a specific COLNUM in ENTRYLIST."
  (seq-max (mapcar (lambda (x) (length (nth colnum x) )) entrylist)))

(defun kubel--buffer-name-from-parameters (context namespace resource)
  "Return a preconfigured kubel buffer name."
  (concat (format "*kubel:%s:%s:%s*" context namespace resource)))

(defun kubel--buffer-name ()
  "Return kubel buffer name."
  (concat (kubel--buffer-name-from-parameters kubel-context
                                                  (if kubel-all-namespaces "all-namespaces" kubel-namespace)
                                                  kubel-resource)
          (unless (equal kubel-selector "")
            (format " (%s)" kubel-selector))))

(defun kubel--items-selected-p ()
  "Return non-nil if there are items selected."
  (>= (length kubel--selected-items) 1))

(defun kubel--print-entry (id cols)
  "Custom entry printer that applies `dired-marked' face to selected items.
ID is the entry identifier (resource name).
COLS is the vector of column values.
When selected, prepends `*' to NAME and applies `dired-marked' face to entire row."
  (let* ((is-selected (-contains? kubel--selected-items id))
         (first-col (aref cols 0))
         (modified-cols (if is-selected
                            (vconcat (vector (propertize (concat "*" first-col) 'face 'dired-marked))
                                     (mapcar (lambda (col) (propertize col 'face 'dired-marked))
                                             (seq-drop cols 1)))
                          cols)))
    (tabulated-list-print-entry id modified-cols)))

(defun kubel--propertize-status (status)
  "Return the status in proper font color.

STATUS is the pod status string."
  (let ((status-face (cdr (assoc status kubel-status-faces)))
        (match (or (equal kubel-resource-filter "") (string-match-p kubel-resource-filter status))))
    (cond (status-face (propertize status 'face status-face))
          ((not match) (propertize status 'face 'shadow))
          (t status))))

(defun kubel--pop-to-buffer (name)
  "Utility function to pop to buffer or create it.

NAME is the buffer name."
  (unless (get-buffer name)
    (get-buffer-create name))
  (pop-to-buffer-same-window name))

(defun kubel--process-error-buffer (process-name)
  "Return the error buffer name for the PROCESS-NAME."
  (format "*%s:err*" process-name))

(defun kubel--sentinel (callback origin error-buffer)
  "Return a sentinel for an async command started in ORIGIN.
Call CALLBACK in the output buffer on success and clean up ERROR-BUFFER."
  (lambda (process _event)
    (when (memq (process-status process) '(exit signal))
      (kubel--activity-stop process)
      (unwind-protect
          (let ((exit-status (process-exit-status process))
                (target (if (buffer-live-p (process-buffer process))
                            (process-buffer process) origin)))
            (kubel--append-to-process-buffer
             (format "[%s]\nexit-code: %s" (process-name process) exit-status))
            (when (buffer-live-p target)
              (with-current-buffer target
                (if (and (eq (process-status process) 'exit) (zerop exit-status))
                    (progn
                      (kubel--clear-header-error)
                      (when callback (funcall callback)))
                  (kubel--handle-stderr
                   (if (buffer-live-p error-buffer)
                       (with-current-buffer error-buffer (buffer-string))
                     (format "Command failed: %s" exit-status)))))))
        (when (buffer-live-p error-buffer)
          (kill-buffer error-buffer))))))

(defun kubel--exec-async (process-name args &optional readonly callback)
  "Run kubectl asynchronously with ARGS, showing output in a buffer.

PROCESS-NAME identifies the process, defaulting to `kubel-command'.
CALLBACK is called in the output buffer when the command succeeds.
READONLY enables `view-mode'.  Show activity in the source and output buffers."
  (when (equal process-name "")
    (setq process-name "kubel-command"))
  (let* ((origin (current-buffer))
         (buffer-name (format "*kubel-resource:%s:%s:%s*" kubel-context (kubel--effective-namespace) (string-join args "_")))
         (error-buffer (generate-new-buffer (kubel--process-error-buffer process-name)))
         (cmd (append (list kubel-kubectl) (kubel--get-context-namespace) args))
         process)
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (kubel--log-command process-name cmd)
    (condition-case err
        (setq process
              (make-process :name process-name
                            :buffer buffer-name
                            :sentinel (kubel--sentinel callback origin error-buffer)
                            :file-handler t
                            :stderr error-buffer
                            :command cmd))
      (error (kill-buffer error-buffer)
             (signal (car err) (cdr err))))
    (when (get-buffer-process error-buffer)
      (set-process-sentinel (get-buffer-process error-buffer) #'ignore)
      (set-process-query-on-exit-flag (get-buffer-process error-buffer) nil))
    (pop-to-buffer-same-window buffer-name)
    (when readonly (view-mode))
    (when (processp process)
      (kubel--activity-start process (list origin (get-buffer buffer-name))
                             (string-join
                              (seq-take args (if (equal (car args) "patch") 3 2))
                              " ")))
    process))

(defun kubel--get-resource-under-cursor ()
  "Return the resource name under point, excluding its namespace."
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "No resource at point"))
    (string-remove-suffix " (default)" (if (consp id) (cdr id) id))))

(defvar kubel--namespace-override nil
  "Namespace explicitly selected for a batch operation.")

(defun kubel--effective-namespace ()
  "Return the selected row's namespace, or the session namespace."
  (let ((id (and (derived-mode-p 'kubel-mode) (tabulated-list-get-id))))
    (or kubel--namespace-override (if (consp id) (car id) kubel-namespace))))

(defun kubel--get-context-namespace (&optional listing)
  "Return context and namespace arguments.
For LISTING, use all namespaces when `kubel-all-namespaces' is enabled.
Single-resource commands always use the selected row's namespace."
  (append
   (unless (or (null kubel-context) (equal kubel-context ""))
     (list "--context" kubel-context))
   (if (and listing kubel-all-namespaces)
       '("--all-namespaces")
     (let ((namespace (if listing kubel-namespace (kubel--effective-namespace))))
       (unless (equal namespace "") (list "-n" namespace))))))

(defun kubel--map-resources (function items)
  "Call FUNCTION with each resource name in ITEMS, in its namespace.
ITEMS contains row IDs, either names or (namespace . name) pairs.
Keep each call in the source buffer even when commands display output buffers."
  (let ((origin (current-buffer))
        (namespace (kubel--effective-namespace)))
    (when (memq nil items) (user-error "No resource at point"))
    (dolist (item items)
      (with-current-buffer origin
        (let ((kubel-namespace (if (consp item) (car item) namespace))
              (kubel--namespace-override (if (consp item) (car item) namespace))
              (kubel-all-namespaces nil))
          (funcall function (if (consp item) (cdr item) item)))))))

(defun kubel--get-selector ()
  "Utility function to return current label selector."
  (unless (equal kubel-selector "")
    (list "--selector" kubel-selector)))

(defun kubel--get-command-prefix ()
  "Utility function to prefix the kubectl command with proper context and namespace.

The label selector is deliberately left out.  kubectl rejects a resource name
combined with `--selector' (\"name cannot be provided when a selector is
specified\"), and `exec' does not accept `--selector' at all.  Use
`kubel--get-list-command-prefix' for commands that list resources."
  (mapconcat 'identity (append (list kubel-kubectl) (kubel--get-context-namespace)) " "))

(defun kubel--get-list-command-prefix ()
  "Utility function to prefix a kubectl command that lists resources.

Same as `kubel--get-command-prefix', with the label selector appended."
  (mapconcat 'identity (append (list kubel-kubectl) (kubel--get-context-namespace t) (kubel--get-selector)) " "))

(defun kubel--get-containers (pod-name &optional type)
  "List the containers in a pod.

POD-NAME is the name of the pod.
TYPE is containers or initContainers."
  (unless type (setq type "containers"))
  (split-string
   (kubel--exec-sync
    (format "%s get pod %s -o jsonpath='{.spec.%s[*].name}'" (kubel--get-command-prefix) pod-name type)) " "))

(defun kubel--get-pod-labels ()
  "List labels of pods in a current namespace."
  (let* ((raw-labels
          (split-string
           (replace-regexp-in-string
            (regexp-quote ":") "="
            (replace-regexp-in-string
             "map\\[\\(.+?\\)\\]" "\\1"
             (kubel--exec-sync
              (format "%s get pod -o jsonpath='{.items[*].metadata.labels}'" (kubel--get-list-command-prefix)))))))
         (splitted (mapcan (lambda (s) (split-string s ","))
                           raw-labels))
         (cleaned (mapcar (lambda (s) (replace-regexp-in-string "[{|\"|}]" "" s)) splitted))
         (unique (-distinct cleaned)))
    unique))

(defun kubel--select-resource (name)
  "Prompt user to select an instance out of a list of resources.

NAME is the string name of the resource."
  (let* ((kubel-namespace (kubel--effective-namespace))
         (kubel-all-namespaces nil)
         (cmd (format "%s get %s -o=jsonpath='{.items[*].metadata.name}'"
                      (kubel--get-list-command-prefix) name)))
    (completing-read (concat (s-upper-camel-case name) ": ")
                     (split-string (kubel--exec-sync cmd) " "))))

(defun kubel--describe-resource (name &optional describe)
  "Describe a specific resource.

NAME is the string name of the resource to decribe.
DESCRIBE is boolean to describe instead of get resource details"
  (let* ((resource (kubel--select-resource name))
         (ctx kubel-context)
         (ns (kubel--effective-namespace))
         (res kubel-resource)
         (process-name (format "kubel - %s - %s" name resource))
         (callback (lambda ()
                     (set-buffer-modified-p nil)
                     (goto-char (point-min)))))
    (if describe
        (kubel--exec-async process-name (list "describe" name resource) nil callback)
      (kubel--exec-async process-name (list "get" name "-o" kubel-output resource) nil callback))
    (when (string-equal kubel-output "yaml")
      (kubel-yaml-editing-mode)
      (setq kubel-context ctx)
      (setq kubel-namespace ns)
      (setq kubel-resource res))))

(defun kubel--show-rollout-revision (type name)
  "Show a specific revision of a certain resource.

TYPE is the resource type.
NAME is the resource name."
  (let* ((typename (format "%s/%s" type name))
         (revision (car (split-string (kubel--select-rollout typename))))
         (process-name (format "kubel - rollout - %s - %s" typename revision))
         (callback (goto-char (point-min))))
    (kubel--exec-async process-name
                 (list "rollout" "history" typename (format "--revision=%s" revision)) nil callback)))

(defun kubel--list-rollout (typename)
  "Return a list of revisions with format '%number   %cause'.

TYPENAME is the resource type/name."
  (let ((cmd (format "%s rollout history %s" (kubel--get-command-prefix) typename)))
    (nthcdr 2 (split-string (kubel--exec-sync cmd) "\n" t))))

(defun kubel--select-rollout (typename)
  "Select a rollout version.

TYPENAME is the resource type/name."
  (let ((prompt (format "Select a rollout of %s: " typename))
        (rollouts (kubel--list-rollout typename)))
    (completing-read prompt rollouts)))

(defun kubel--is-pod-view ()
  "Return non-nil if this is the pod view."
  (equal (capitalize kubel-resource) "Pods"))

(defun kubel--is-deployment-view ()
  "Return non-nil if this is a deployment view."
  (-contains? '("Deployments" "deployments" "deployments.apps") kubel-resource))

(defun kubel--is-scalable ()
  "Return non-nil if the resource can be scaled."
  (or
   (kubel--is-deployment-view)
   (-contains? '("ReplicaSets" "replicasets" "replicasets.apps") kubel-resource)
   (-contains? '("StatefulSets" "statefulsets" "statefulsets.apps") kubel-resource)))

(defun kubel-kill-buffer ()
  "Kill the current buffer."
  (interactive)
  (when (or (not (buffer-modified-p))
	    (not kubel-kill-buffer-query)
	    (yes-or-no-p "Resource modified; kill anyway? "))
    (kill-buffer (current-buffer))))

(defun kubel-go-back ()
  "Kill current buffer and return to parent kubel buffer.
If no parent buffer exists, call `quit-window'."
  (interactive)
  (let ((parent kubel--parent-buffer))
    (if (and parent (buffer-live-p parent))
        (progn
          (kill-buffer (current-buffer))
          (switch-to-buffer parent)
          ;; Re-display error overlay if there was an error
          (when kubel--header-error
            (kubel--set-header-error kubel--header-error)))
      (quit-window))))

(defun kubel-kill-all-buffers ()
  "Kill all kubel-related buffers."
  (interactive)
  (dolist (buf (buffer-list))
    (when (string-match-p "^\\*kubel\\(-resource\\)?:" (buffer-name buf))
      (kill-buffer buf))))

(defvar kubel-yaml-editing-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'kubel-apply)
    (define-key map (kbd "C-c C-k") #'kubel-kill-buffer)
    map)
  "Keymap used in `kubel-yaml-editing-mode' buffers.")

;; interactive
;;;###autoload
(define-derived-mode kubel-yaml-editing-mode yaml-mode "kubel/e"
  "Kubel Yaml editing mode.

Allows simple apply of the changes made.

\\{kubel-yaml-editing-mode-map}")

(defun kubel-apply ()
  "Save the current buffer to a temp file and try to kubectl apply it."
  (interactive)
  (setq dir-prefix (or
                    (when (tramp-tramp-file-p default-directory)
                      (with-parsed-tramp-file-name default-directory nil
                        (format "/%s%s:%s:" (or hop "") method (if user (concat user "@" host) host))))
                    ""))
  (let* ((filename-without-tramp-prefix (format "/tmp/kubel/%s-%s.yaml"
                                                (replace-regexp-in-string "/" "_"
                                                                          (replace-regexp-in-string "\*\\| " "" (buffer-name)))
                                                (floor (float-time))))
         (filename (format "%s%s" dir-prefix filename-without-tramp-prefix)))
    (when (y-or-n-p "Apply the changes? ")
      (unless  (file-exists-p (format "%s/tmp/kubel" dir-prefix))
        (make-directory (format "%s/tmp/kubel" dir-prefix) t))
      (write-region (point-min) (point-max) filename)
      (kubel--exec-async (format "kubectl - apply - %s" filename) (list "apply" "-f" filename-without-tramp-prefix) nil (lambda () (message "Applied %s" filename))))))

(defun kubel-get-resource-details (&optional describe)
  "Get the details of the resource under the cursor.

 DESCRIBE is the optional param to describe instead of get."
  (interactive "P")
  (let* ((resource (kubel--get-resource-under-cursor))
         (ctx kubel-context)
         (ns (kubel--effective-namespace))
         (res kubel-resource)
         (process-name (format "kubel - %s - %s" kubel-resource resource))
         (callback (lambda ()
                     (setq kubel-context ctx)
                     (setq kubel-namespace ns)
                     (setq kubel-resource res)
                     (set-buffer-modified-p nil)
                     (goto-char (point-min)))))
    (if describe
        (kubel--exec-async process-name (list "describe" kubel-resource (kubel--get-resource-under-cursor)) t callback)
      (kubel--exec-async process-name (list "get" kubel-resource (kubel--get-resource-under-cursor) "-o" kubel-output) t callback))))

(defun kubel--default-tail-arg (args)
  "Ugly function to make sure that there is at least the default tail.

ARGS is the arg list from transient."
  (if (car (remove nil (mapcar (lambda (x)
                                 (string-prefix-p "--tail=" x)) args)))
      args
    (append args (list (concat "--tail=" (format "%s" kubel-log-tail-n))))))

(defun kubel-get-pod-logs (&optional args type)
  "Get the last N logs of the pod under the cursor.

ARGS is the arguments list from transient.
TYPE is containers or initContainers."
  (interactive
   (list (transient-args 'kubel-log-popup)))
  (kubel--map-resources
   (lambda (pod)
     (let* ((type (or type "containers"))
            (containers (kubel--get-containers pod type))
            (container (if (equal (length containers) 1)
                           (car containers)
                         (completing-read "Select container: " containers)))
            (process-name (format "kubel - logs - %s - %s" pod container)))
       (kubel--exec-async process-name
                          (append '("logs") (kubel--default-tail-arg args)
                                  (list pod container)) t nil)))
   (if (kubel--is-pod-view)
       (or kubel--selected-items (list (tabulated-list-get-id)))
     (list (kubel--select-resource "Pods")))))

(defun kubel-get-pod-logs--initContainer (&optional args)
  "Get the last N logs of the pod under the cursor.

ARGS is the arguments list from transient."
  (interactive
   (list (transient-args 'kubel-log-popup)))
  (kubel-get-pod-logs args "initContainers"))

(defun kubel-get-logs-by-labels (&optional args)
  "Get the last N logs of the pods by labels.
ARGS is the arguments list from transient."
  (interactive
   (list (transient-args 'kubel-log-popup)))
  (let* ((labels (kubel--get-pod-labels))
         (label (completing-read "Select container: " labels))
         (process-name (format "kubel - logs - %s" label)))
    (kubel--exec-async process-name
                 (append '("logs") (kubel--default-tail-arg args) '("-l") (list label)) t nil)))

(defun kubel-copy-resource-name ()
  "Copy the name of the pod under the cursor."
  (interactive)
  (kill-new (kubel--get-resource-under-cursor))
  (message "Resource name copied to kill-ring"))

(defun kubel-copy-log-command ()
  "Copy the streaming log command of the pod under the cursor."
  (interactive)
  (kill-new
   (format "%s logs -f --tail=%s %s"
           (kubel--get-command-prefix)
           kubel-log-tail-n
           (if (kubel--is-pod-view)
               (kubel--get-resource-under-cursor)
             (kubel--select-resource "Pods"))))
  (message "Log command copied to kill-ring"))

(defun kubel-copy-command-prefix ()
  "Copy the kubectl command prefix."
  (interactive)
  (kill-new (kubel--get-command-prefix))
  (message "Command prefix copied to kill-ring"))

(defun kubel-copy-last-command ()
  "Copy the last kubectl command ran."
  (interactive)
  (kill-new kubel--last-command)
  (message (concat "Last command copied: " kubel--last-command)))

(defun kubel-set-kubectl-config-file (configfile)
  "Set the path to the kubectl CONFIGFILE."
  (interactive "f")
  (let ((configfile (or configfile "~/.kube/config")))
    (if (file-exists-p (expand-file-name configfile))
        (setenv "KUBECONFIG" (expand-file-name configfile))
      (error "Kubectl config file '%s' does not exist!" configfile))))

(defcustom kubel-namespace-cache-ttl 300
  "Seconds namespace completion data stays fresh.
Nil means cached results never expire; zero revalidates on every invocation.
Expired results remain usable while they refresh asynchronously."
  :type '(choice (const :tag "Never expire" nil) (number :tag "Seconds"))
  :group 'kubel)

(defcustom kubel-namespace-request-timeout "30s"
  "Kubectl request timeout for background namespace discovery."
  :type 'string
  :group 'kubel)

(defcustom kubel-namespace-cache-retry-delay 30
  "Seconds to wait before automatically retrying a failed namespace request.
A prefix argument to `kubel-set-namespace' bypasses this delay."
  :type 'number
  :group 'kubel)

(cl-defstruct (kubel--namespace-entry (:constructor kubel--make-namespace-entry))
  names fetched-at permission permission-at retry-after process callbacks)

(defvar kubel--namespace-cache (make-hash-table :test #'equal)
  "Namespace completion entries keyed by context and execution configuration.")

(defvar-local kubel--namespace-prompt-token nil
  "Identity of the latest namespace selection requested in this buffer.")

(defun kubel--namespace-normalize-path (path directory)
  "Normalize PATH against DIRECTORY without accessing the filesystem.
DIRECTORY is local, or the local part of a TRAMP directory.  Preserve a
relative remote directory when its absolute location is not yet known."
  (if (and (file-name-absolute-p path) (not (string-prefix-p "~" path)))
      (expand-file-name path "/")
    (if (and (file-name-absolute-p directory)
             (not (string-prefix-p "~" directory)))
        ;; KUBECONFIG is a literal path list: kubectl does not expand tildes.
        (expand-file-name (concat "./" path) directory)
      (list :directory directory :path path))))

(defun kubel--completion-cache-key ()
  "Identify completion execution settings independently of local working folders.
Resolve relative kubeconfig and executable paths lexically.  Remote keys
include the TRAMP connection identity without opening a connection."
  (let* ((remote (file-remote-p default-directory))
         (directory (if remote (file-remote-p default-directory 'localname)
                      default-directory))
         (config (getenv "KUBECONFIG"))
         (configs
          (if (and config (not (string-empty-p config)))
              (delete-dups
               (mapcar (lambda (path) (kubel--namespace-normalize-path path directory))
                       (split-string config (regexp-quote (if remote ":" path-separator)) t)))
            (list (if remote :default-kubeconfig
                    (expand-file-name ".kube/config" (expand-file-name "~/" "/"))))))
         (executable (if (string-match-p "[/\\\\]" kubel-kubectl)
                         (kubel--namespace-normalize-path kubel-kubectl directory)
                       kubel-kubectl)))
    (list kubel-context executable configs remote)))

(defun kubel--namespace-cache-key ()
  "Identify namespace completion settings, including its permission policy."
  (append (kubel--completion-cache-key) (list kubel-use-namespace-list)))

(defun kubel--namespace-entry ()
  "Return or create the namespace completion entry for this session."
  (let* ((key (kubel--namespace-cache-key))
         (entry (gethash key kubel--namespace-cache)))
    (or entry
        (puthash key (kubel--make-namespace-entry) kubel--namespace-cache))))

(defun kubel--cache-fresh-p (timestamp ttl)
  "Return non-nil if TIMESTAMP is fresh according to TTL seconds."
  (and timestamp (or (null ttl) (< (- (float-time) timestamp) ttl))))

(defun kubel--namespace-fresh-p (timestamp)
  "Return non-nil if TIMESTAMP is within the namespace cache TTL."
  (kubel--cache-fresh-p timestamp kubel-namespace-cache-ttl))

(defun kubel--namespace-candidates ()
  "Return cached names plus history and defaults without contacting Kubernetes."
  (let ((entry (kubel--namespace-entry)))
    (delete-dups
     (append (unless (or (eq kubel-use-namespace-list 'off)
                         (eq (kubel--namespace-entry-permission entry) 'denied))
               (copy-sequence (kubel--namespace-entry-names entry)))
             (copy-sequence kubel-namespace-history)
             (unless (string-empty-p kubel-namespace) (list kubel-namespace))
             (list kubel-default-namespace)))))

(defun kubel--completion-exec (command origin label callback)
  "Run completion COMMAND independently of resource-table refreshes.
Show activity LABEL in ORIGIN; pass exit status, stdout and stderr to CALLBACK.
Execution uses the current `default-directory' and `process-environment'."
  (let ((stdout (generate-new-buffer " *kubel-completion*"))
        (stderr (generate-new-buffer " *kubel-completion-stderr*")))
    (condition-case err
        (let ((process
               (make-process
                :name "kubel-completion" :buffer stdout :stderr stderr
                :command command :connection-type 'pipe :noquery t :file-handler t
                :sentinel
                (lambda (process _event)
                  (when (and (memq (process-status process) '(exit signal))
                             (not (process-get process 'kubel-completion-finished)))
                    (process-put process 'kubel-completion-finished t)
                    (let ((status (process-exit-status process))
                          (output (with-current-buffer stdout (buffer-string)))
                          (errors (with-current-buffer stderr (buffer-string))))
                      (unwind-protect
                          (progn
                            (kubel--append-to-process-buffer
                             (format "[kubel-completion]\nexit-code: %s" status))
                            (unless (string-empty-p (string-trim errors))
                              (kubel--append-to-process-buffer
                               (format "stderr: %s" (string-trim errors)))))
                        (kubel--activity-stop process)
                        (kill-buffer stdout)
                        (kill-buffer stderr))
                      (funcall callback status output errors)))))))
          (unless (processp process)
            (error "Asynchronous completion requests are unavailable here"))
          (when (get-buffer-process stderr)
            (set-process-sentinel (get-buffer-process stderr) #'ignore)
            (set-process-query-on-exit-flag (get-buffer-process stderr) nil))
          (when (buffer-live-p origin)
            (with-current-buffer origin
              (kubel--log-command "kubel-completion" command)))
          (kubel--activity-start process (list origin) label)
          process)
      (error
       (kill-buffer stdout)
       (kill-buffer stderr)
       (funcall callback 'failed "" (error-message-string err))
       nil))))

(defun kubel--namespace-exec (entry command origin callback)
  "Run namespace COMMAND for ENTRY in ORIGIN, then call CALLBACK."
  (setf (kubel--namespace-entry-process entry)
        (kubel--completion-exec
         command origin "Updating namespaces"
         (lambda (status output errors)
           (setf (kubel--namespace-entry-process entry) nil)
           (funcall callback status output errors)))))

(defun kubel--namespace-finish (entry &optional error-message)
  "Finish updating ENTRY and notify its waiting callers.
Preserve old data and delay retries when ERROR-MESSAGE is non-nil."
  (when error-message
    (setf (kubel--namespace-entry-retry-after entry)
          (+ (float-time) kubel-namespace-cache-retry-delay))
    (kubel--append-to-process-buffer
     (format "Namespace refresh failed: %s" (string-trim error-message)))
    (message "Kubel namespace refresh failed; using cached names or history"))
  (let ((callbacks (kubel--namespace-entry-callbacks entry)))
    (setf (kubel--namespace-entry-callbacks entry) nil)
    (dolist (callback callbacks)
      ;; Never open a completion prompt inside a process sentinel.
      (run-at-time 0 nil callback))))

(defun kubel--refresh-namespace-cache (&optional force callback)
  "Refresh this session's namespace cache asynchronously if needed.
FORCE bypasses freshness and retry delays.  CALLBACK runs when the request
finishes, including failures.  Concurrent callers share the pending request."
  (let* ((entry (kubel--namespace-entry))
         (origin (current-buffer))
         (directory default-directory)
         (environment (copy-sequence process-environment))
         (policy kubel-use-namespace-list)
         (prefix (append (list kubel-kubectl)
                         (when (and kubel-context (not (string-empty-p kubel-context)))
                           (list "--context" kubel-context))
                         (list (concat "--request-timeout=" kubel-namespace-request-timeout)))))
    (cond
     ((eq policy 'off) (when callback (funcall callback)))
     ((processp (kubel--namespace-entry-process entry))
      (when callback (push callback (kubel--namespace-entry-callbacks entry))))
     ((and (not force)
           (or (and (kubel--namespace-entry-retry-after entry)
                    (< (float-time) (kubel--namespace-entry-retry-after entry)))
               (and (eq (kubel--namespace-entry-permission entry) 'denied)
                    (kubel--namespace-fresh-p (kubel--namespace-entry-permission-at entry)))
               (kubel--namespace-fresh-p (kubel--namespace-entry-fetched-at entry))))
      (when callback (funcall callback)))
     (t
      (when callback (push callback (kubel--namespace-entry-callbacks entry)))
      (cl-labels
          ((run (args handler)
             (let ((default-directory directory)
                   (process-environment environment))
               (kubel--namespace-exec entry (append prefix args) origin handler)))
           (failed (errors)
             (kubel--namespace-finish entry
                                      (if (string-empty-p (string-trim errors))
                                          "Namespace command failed" errors)))
           (fetch ()
             (run '("get" "namespaces" "-o" "jsonpath={.items[*].metadata.name}")
                  (lambda (status output errors)
                    (if (equal status 0)
                        (progn
                          (setf (kubel--namespace-entry-names entry)
                                (sort (delete-dups (split-string output "[ \t\r\n]+" t)) #'string-lessp)
                                (kubel--namespace-entry-fetched-at entry) (float-time)
                                (kubel--namespace-entry-permission entry) 'allowed
                                (kubel--namespace-entry-permission-at entry) (float-time)
                                (kubel--namespace-entry-retry-after entry) nil)
                          (kubel--namespace-finish entry))
                      (failed errors))))))
        (if (or (eq policy 'on)
                (and (not force)
                     (eq (kubel--namespace-entry-permission entry) 'allowed)
                     (kubel--namespace-fresh-p (kubel--namespace-entry-permission-at entry))))
            (fetch)
          (run '("auth" "can-i" "list" "namespaces")
               (lambda (status output errors)
                 (cond
                  ((and (equal status 0) (equal (string-trim output) "yes"))
                   (setf (kubel--namespace-entry-permission entry) 'allowed
                         (kubel--namespace-entry-permission-at entry) (float-time))
                   (fetch))
                  ((and (memq status '(0 1)) (equal (string-trim output) "no"))
                   (setf (kubel--namespace-entry-permission entry) 'denied
                         (kubel--namespace-entry-permission-at entry) (float-time)
                         (kubel--namespace-entry-retry-after entry) nil)
                   (message "Kubel cannot list namespaces; using namespace history")
                   (kubel--namespace-finish entry))
                  (t (failed errors)))))))))))

(defun kubel--list-namespace ()
  "Return namespace candidates immediately and revalidate them in the background."
  (prog1 (kubel--namespace-candidates)
    (kubel--refresh-namespace-cache)))

(defun kubel--add-namespace-to-history (namespace)
  "Add NAMESPACE to history if it isn't there already."
  (unless (member namespace kubel-namespace-history)
    (push namespace kubel-namespace-history)))

(defun kubel-list-namespaces ()
  "List all namespaces in the current context."
  (interactive)
  (let* ((kubel--buffer (get-buffer (kubel--buffer-name)))
         (parent-buffer (current-buffer))
         (last-default-directory (when kubel--buffer
                                   (with-current-buffer kubel--buffer default-directory))))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-resource "namespaces"
            kubel-all-namespaces nil
            kubel--selected-items nil)
      (setq kubel-selector "")
      (switch-to-buffer (current-buffer))
      (kubel-refresh last-default-directory))))

(defun kubel--open-namespace (namespace)
  "Open a cloned session for NAMESPACE, preserving the current session."
  (let ((parent-buffer (current-buffer))
        (directory default-directory)
        (from-namespace-list (equal kubel-resource "namespaces")))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer
            kubel-namespace namespace
            kubel-all-namespaces nil
            kubel--selected-items nil)
      (when from-namespace-list (setq kubel-resource "pods"))
      (kubel--add-namespace-to-history namespace)
      (switch-to-buffer (current-buffer))
      (kubel-refresh directory))))

(defun kubel--prompt-namespace (candidates)
  "Prompt using CANDIDATES and open the chosen namespace."
  (kubel--open-namespace
   (completing-read "Namespace: " candidates nil nil nil nil kubel-default-namespace)))

(defun kubel--namespace-prompt-ready (origin key token)
  "Open the namespace prompt for ORIGIN if KEY and TOKEN still match.
Wait until any existing minibuffer prompt has closed."
  (when (and (buffer-live-p origin)
             (with-current-buffer origin
               (and (derived-mode-p 'kubel-mode)
                    (eq token kubel--namespace-prompt-token)
                    (equal key (kubel--namespace-cache-key)))))
    (if (active-minibuffer-window)
        (run-at-time 0.1 nil #'kubel--namespace-prompt-ready origin key token)
      (pop-to-buffer-same-window origin)
      (setq kubel--namespace-prompt-token nil)
      (kubel--prompt-namespace (kubel--namespace-candidates)))))

(defun kubel-set-namespace (&optional refresh)
  "Choose a namespace using cached completion candidates immediately.
Revalidate expired candidates asynchronously.  With prefix argument REFRESH,
fetch fresh candidates asynchronously before opening the prompt; retain cached
names or history if fetching fails.  Other resource caches are unaffected.
When viewing namespaces, select the namespace under point or the single mark."
  (interactive "P")
  (setq kubel--namespace-prompt-token nil)
  (cond
   ((equal kubel-resource "namespaces")
    (kubel--open-namespace
     (cond ((> (length kubel--selected-items) 1)
            (user-error "Cannot set namespace: multiple namespaces are marked"))
           (kubel--selected-items (car kubel--selected-items))
           (t (kubel--get-resource-under-cursor)))))
   (refresh
    (let ((origin (current-buffer))
          (key (kubel--namespace-cache-key))
          (token (list 'namespace-prompt)))
      (setq kubel--namespace-prompt-token token)
      (kubel--refresh-namespace-cache
       t (lambda () (kubel--namespace-prompt-ready origin key token)))))
   (t (kubel--prompt-namespace (kubel--list-namespace)))))

(defun kubel-set-context ()
  "Set the context."
  (interactive)
  (let* ((kubel--buffer (get-buffer (kubel--buffer-name)))
         (parent-buffer (current-buffer))
         (last-default-directory (when kubel--buffer (with-current-buffer kubel--buffer default-directory))))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (setq kubel-context
            (completing-read
             "Select context: "
             (split-string (kubel--exec-sync (format "%s config view -o jsonpath='{.contexts[*].name}'" kubel-kubectl)) " ")))
      (kubel--invalidate-context-caches)
      (setq kubel-namespace "default"
            kubel-all-namespaces nil
            kubel--selected-items nil)
      (switch-to-buffer (current-buffer))
      (kubel-refresh last-default-directory))))

(defun kubel--add-selector-to-history (selector)
  "Add SELECTOR to history if it isn't there already."
  (unless (member selector kubel-selector-history)
    (push selector kubel-selector-history)))

(defun kubel--get-all-selectors ()
  "Get all selectors."
  (unless kubel--label-values-cached
    (let ((labels (kubel--get-pod-labels)))
      (setq kubel--label-values-cached labels)))
  kubel--label-values-cached)

(defun kubel--list-selectors ()
  "List selector expressions from history."
  (delete-dups
   (append '("none") (kubel--get-all-selectors)
           kubel-selector-history)))

(defun kubel-set-label-selector ()
  "Set the selector."
  (interactive)
  (let ((parent-buffer (current-buffer)))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer)
      (let ((selector (completing-read
                     "Selector: "
                     (kubel--list-selectors))))
      (when (equal selector "none")
        (setq selector ""))
      (setq kubel-selector selector))
      (kubel--add-selector-to-history kubel-selector)
      ;; Update pod list according to the label selector
      (switch-to-buffer (current-buffer))
      (kubel-refresh))))

(defcustom kubel-resource-cache-ttl 300
  "Seconds API resource completion data stays fresh.
Nil means cached results never expire; zero revalidates on every invocation."
  :type '(choice (const :tag "Never expire" nil) (number :tag "Seconds"))
  :group 'kubel)

(defcustom kubel-resource-cache-retry-delay 30
  "Seconds before retrying failed API resource discovery automatically.
A prefix argument to `kubel-set-resource' bypasses this delay."
  :type 'number
  :group 'kubel)

(defcustom kubel-resource-request-timeout "30s"
  "Kubectl request timeout for background API resource discovery."
  :type 'string
  :group 'kubel)

(cl-defstruct (kubel--resource-entry (:constructor kubel--make-resource-entry))
  names fetched-at retry-after process callbacks)

(defvar kubel--resource-cache (make-hash-table :test #'equal)
  "API resource lists shared by sessions using the same execution configuration.")

(defvar kubel-resource-history nil
  "Previously chosen resource types, available before discovery completes.")

(defvar-local kubel--resource-prompt-token nil
  "Identity of the latest resource selection requested in this buffer.")

(defun kubel--resource-entry ()
  "Return or create this execution configuration's API resource cache entry."
  (let* ((key (kubel--completion-cache-key))
         (entry (gethash key kubel--resource-cache)))
    (or entry (puthash key (kubel--make-resource-entry) kubel--resource-cache))))

(defun kubel--resource-candidates ()
  "Return cached resource names, history and defaults without issuing requests."
  (delete-dups
   (append (copy-sequence (kubel--resource-entry-names (kubel--resource-entry)))
           (copy-sequence kubel-resource-history)
           (list kubel-resource "pods"))))

(defun kubel--refresh-resource-cache (&optional force callback)
  "Revalidate this configuration's API resource list asynchronously.
FORCE bypasses freshness and retry delays.  CALLBACK runs after completion,
including failures.  Concurrent callers share one pending request."
  (let ((entry (kubel--resource-entry)))
    (cond
     ((processp (kubel--resource-entry-process entry))
      (when callback (push callback (kubel--resource-entry-callbacks entry))))
     ((and (not force)
           (or (kubel--cache-fresh-p (kubel--resource-entry-fetched-at entry)
                                     kubel-resource-cache-ttl)
               (and (kubel--resource-entry-retry-after entry)
                    (< (float-time) (kubel--resource-entry-retry-after entry)))))
      (when callback (funcall callback)))
     (t
      (when callback (push callback (kubel--resource-entry-callbacks entry)))
      (let ((retry-delay kubel-resource-cache-retry-delay))
        (setf (kubel--resource-entry-process entry)
              (kubel--completion-exec
               (append (list kubel-kubectl)
                       (when (and kubel-context (not (string-empty-p kubel-context)))
                         (list "--context" kubel-context))
                       (list (concat "--request-timeout=" kubel-resource-request-timeout)
                             "api-resources" "-o" "name" "--no-headers=true"))
               (current-buffer) "Updating resource types"
               (lambda (status output errors)
                 (setf (kubel--resource-entry-process entry) nil)
                 (if (equal status 0)
                     (setf (kubel--resource-entry-names entry)
                           (sort (delete-dups (split-string output "[ \t\r\n]+" t)) #'string-lessp)
                           (kubel--resource-entry-fetched-at entry) (float-time)
                           (kubel--resource-entry-retry-after entry) nil)
                   (setf (kubel--resource-entry-retry-after entry)
                         (+ (float-time) retry-delay))
                   (kubel--append-to-process-buffer
                    (format "API resource discovery failed: %s" (string-trim errors)))
                   (message "Kubel resource discovery failed; using cached resource types or history"))
                 (let ((callbacks (kubel--resource-entry-callbacks entry)))
                   (setf (kubel--resource-entry-callbacks entry) nil)
                   (dolist (callback callbacks)
                     (run-at-time 0 nil callback)))))))))))

(defun kubel--kubernetes-resources-list ()
  "Return cached resource candidates and revalidate asynchronously."
  (prog1 (kubel--resource-candidates)
    (kubel--refresh-resource-cache)))

(defun kubel--open-resource (resource)
  "Open a cloned resource session for RESOURCE."
  (let ((parent-buffer (current-buffer))
        (directory default-directory))
    (with-current-buffer (clone-buffer)
      (setq kubel--parent-buffer parent-buffer
            kubel-resource resource
            kubel--selected-items nil)
      (cl-pushnew resource kubel-resource-history :test #'equal)
      (switch-to-buffer (current-buffer))
      (kubel-refresh directory))))

(defun kubel--prompt-resource (candidates)
  "Prompt using CANDIDATES and open the chosen resource view."
  (kubel--open-resource
   (completing-read "Select resource: " candidates nil nil nil
                    'kubel-resource-history kubel-resource)))

(defun kubel--resource-prompt-ready (origin key token)
  "Prompt in ORIGIN if its execution KEY and pending selection TOKEN still match."
  (when (and (buffer-live-p origin)
             (with-current-buffer origin
               (and (derived-mode-p 'kubel-mode)
                    (eq token kubel--resource-prompt-token)
                    (equal key (kubel--completion-cache-key)))))
    (if (active-minibuffer-window)
        (run-at-time 0.1 nil #'kubel--resource-prompt-ready origin key token)
      (pop-to-buffer-same-window origin)
      (setq kubel--resource-prompt-token nil)
      (kubel--prompt-resource (kubel--resource-candidates)))))

(defun kubel-set-resource (&optional refresh)
  "Choose a resource type from cached candidates immediately.
Expired or missing discovery data refreshes asynchronously.  With prefix
argument REFRESH, fetch fresh candidates before prompting.  On failure retain
cached names or history.  Namespace and label caches are unaffected."
  (interactive "P")
  (setq kubel--resource-prompt-token nil)
  (if refresh
      (let ((origin (current-buffer))
            (key (kubel--completion-cache-key))
            (token (list 'resource-prompt)))
        (setq kubel--resource-prompt-token token)
        (kubel--refresh-resource-cache
         t (lambda () (kubel--resource-prompt-ready origin key token))))
    (kubel--prompt-resource (kubel--kubernetes-resources-list))))

(defun kubel-set-output-format ()
  "Set output format of kubectl."
  (interactive)
  (setq kubel-output
        (completing-read
         "Set output format: "
         '("yaml" "json" "wide" "custom-columns="))))

(defun kubel-port-forward-pod (p)
  "Port forward a pod to your local machine.

P can be a single number or a localhost:container port pair."
  (interactive "sPort: ")
  (let* ((port (if (string-match-p ":" p) p (format "%s:%s" p p)))
         (pod (if (kubel--is-pod-view)
                  (kubel--get-resource-under-cursor)
                (kubel--select-resource "Pods")))
         (process-name (format "kubel - port-forward - %s:%s" pod port)))
    (kubel--exec-async process-name (list "port-forward" pod port))))

(defvar kubel--tramp-method-cache nil
  "Alist mapping (context . namespace) to TRAMP method names.
Names are \"kubel\", \"kubel1\", \"kubel2\", etc.")

(defun kubel--get-tramp-method ()
  "Return the TRAMP method name for the current context and namespace.
Reuses an existing method if one has already been registered for
this combination, otherwise creates a new one with the next
available name (kubel, kubel1, kubel2, ...)."
  (let* ((key (cons (or kubel-context "") (or (kubel--effective-namespace) "")))
         (cached (assoc key kubel--tramp-method-cache)))
    (if cached
        (cdr cached)
      (let* ((idx (length kubel--tramp-method-cache))
             (name (if (= idx 0) "kubel" (format "kubel%d" idx))))
        (add-to-list 'tramp-methods
                     `(,name
                       (tramp-login-program      ,kubel-kubectl)
                       (tramp-login-args         (,(kubel--get-context-namespace) ("exec" "-it") ("-c" "%u") ("%h") ("--" "sh")))
                       (tramp-remote-shell       "sh")
                       (tramp-remote-shell-args  ("-i" "-c"))))
        (push (cons key name) kubel--tramp-method-cache)
        name))))

(defun kubel--tramp-url (con-pod)
  "Build a TRAMP URL for CON-POD `(container . pod)' in current context/namespace."
  (let ((dir-prefix (kubel--dir-prefix))
        (method (kubel--get-tramp-method)))
    (format "/%s%s:%s@%s:/" dir-prefix method (car con-pod) (cdr con-pod))))

(defun kubel--get-container-under-cursor ()
  "Get `(container . pod)' name under cursor."
  (let* ((pod (if (kubel--is-pod-view)
                  (kubel--get-resource-under-cursor)
                (kubel--select-resource "Pods")))
         (containers (kubel--get-containers pod))
         (container (if (equal (length containers) 1)
                        (car containers)
                      (completing-read "Select container: " containers))))
    (cons container pod)))

(defun kubel--dir-prefix ()
  "Return the current directory prefix for a TRAMP connection."
  (or
   (when (tramp-tramp-file-p default-directory)
     (with-parsed-tramp-file-name default-directory nil
       (format "%s%s:%s|" (or hop "") method (if user (concat user "@" host) host))))
   ""))

(defun kubel-exec-pod ()
  "Exec into the pod under the cursor -> `find-file."
  (interactive)
  (find-file (kubel--tramp-url (kubel--get-container-under-cursor))))

(defun kubel--shell-buffer-name (shell-type container pod)
  "Generate the name for a pod's shell buffer.

This uses `kubel-shell-buffer-name-format' as the buffer name
format. See the documentation for it for more information on how
to set this format.

The values for the current namespace and context are pulled from
the variables `kubel-namespace' and `kubel-context', respectively."
  (format-spec kubel-shell-buffer-name-format
               `((?t . ,shell-type)
                 (?c . ,container)
                 (?p . ,pod)
                 (?n . ,(kubel--effective-namespace))
                 (?C . ,kubel-context))))

(defun kubel-exec-shell-pod ()
  "Exec into the pod under the cursor -> shell."
  (interactive)
  (let* ((con-pod (kubel--get-container-under-cursor))
         (default-directory (kubel--tramp-url con-pod)))
    (shell (kubel--shell-buffer-name "shell" (car con-pod) (cdr con-pod)))))

(defun kubel-exec-eshell-pod ()
  "Exec into the pod under the cursor -> eshell."
  (interactive)
  (let* ((con-pod (kubel--get-container-under-cursor))
         (default-directory (kubel--tramp-url con-pod))
         (eshell-buffer-name
          (kubel--shell-buffer-name "eshell" (car con-pod) (cdr con-pod))))
    (eshell)))

(defun kubel-exec-vterm-pod ()
  "Exec into the pod under the cursor -> vterm."
  (interactive)
  (let* ((con-pod (kubel--get-container-under-cursor))
         (default-directory (kubel--tramp-url con-pod))
         (vterm-buffer-name
          (kubel--shell-buffer-name "vterm" (car con-pod) (cdr con-pod)))
         (vterm-shell "/bin/sh"))
    (vterm nil)))

;;;###autoload
(defun kubel-vterm-setup ()
  "Adds a vterm enty to the KUBEL-EXEC-POP."
  (require 'vterm)
  (transient-append-suffix 'kubel-exec-popup "e"
    '("v" "Vterm" kubel-exec-vterm-pod)))

(defun kubel-exec-ansi-term-pod ()
  "Exec into the pod under the cursor -> `ansi-term'."
  (interactive)
  (let* ((con-pod (kubel--get-container-under-cursor))
         (container (car con-pod))
         (pod (cdr con-pod))
         (command (format "%s exec %s -c %s -i -t -- /usr/bin/env sh" (kubel--get-command-prefix) pod container)))
    (with-current-buffer (ansi-term "bash" (kubel--shell-buffer-name "ansi-term" container pod))
      (process-send-string (current-buffer) (format "%s\n" command)))))

(defun kubel-exec-eat-pod ()
  "Exec into the pod under the cursor -> eat."
  (interactive)
  (unless (fboundp 'eat-other-window)
    (user-error "This command requires the `eat' package."))
  (let* ((con-pod (kubel--get-container-under-cursor))
         (default-directory (kubel--tramp-url con-pod))
         (eat-shell "sh")
         (eat-buffer-name (format "*eat:%s" default-directory)))
    (eat-other-window)))

(defun kubel-exec-pod-by-shell-command ()
  "Prompt shell with kubectl exec command at pod under cursor."
  (interactive)
  (let* ((con-pod (kubel--get-container-under-cursor))
         (command (read-string "Shell command: " (format "%s exec %s -c %s -- " (kubel--get-command-prefix) (cdr con-pod) (car con-pod)))))
    (shell-command command)))

(defun kubel-delete-resource ()
  "Delete the selected resources in their respective namespaces."
  (interactive)
  (let ((force (transient-args 'kubel-delete-popup)))
    (kubel--map-resources
     (lambda (name)
       (kubel--exec-async
        (format "kubel - delete %s - %s" kubel-resource name)
        (append (list "delete" kubel-resource name)
                (when force '("--force" "--grace-period=0")))))
     (or kubel--selected-items (list (tabulated-list-get-id))))))

(defun kubel-restart-deployment ()
  "Restart selected deployments using `kubectl rollout restart'."
  (interactive)
  (kubel--map-resources
   (lambda (deployment)
     (kubel--exec-async (format "kubel - restart - %s" deployment)
                        (list "rollout" "restart" (concat "deployment/" deployment))))
   (if (kubel--is-deployment-view)
       (or kubel--selected-items (list (tabulated-list-get-id)))
     (list (kubel--select-resource "Deployments")))))

(defalias 'kubel-jab-deployment #'kubel-restart-deployment)

(defun kubel-scale-replicas (replicas)
  "Scale resource replicas.

REPLICAS is the number of desired replicas."
  (interactive (list (read-number "Replicas: ")))
  (if (kubel--is-scalable)
      (let* ((resource (kubel--get-resource-under-cursor))
             (process-name (format "kubel:scale:%s/%s" kubel-resource resource)))
        (kubel--exec-async process-name (list "scale" kubel-resource resource "--replicas" (number-to-string replicas))))
    (message
     "[%s] cannot be scaled.\nOnly these resources can be scaled: [deployment, replica set, replication controller, and stateful set]."
     kubel-resource)))

(defun kubel-set-filter (filter)
  "Set the pod filter.

FILTER is the filter string."
  (interactive "MFilter: ")
  (setq kubel-resource-filter filter)
  (kubel-refresh))

(defun kubel--jump-to-highlight (init search reset)
  "Base function to jump to highlight.

INIT is to be called before searching.
SEARCH is to apply the search and can be repeated safely.
RESET is to be called if the search is nil after the first attempt."
  (unless (equal kubel-resource-filter "")
    (funcall init)
    (unless (funcall search)
      (funcall reset)
      (funcall search))
    (beginning-of-line)))

(defun kubel-jump-to-next-highlight ()
  "Jump to the next hightlighted resrouce."
  (interactive)
  (kubel--jump-to-highlight
   #'end-of-line
   (lambda () (re-search-forward kubel-resource-filter (point-max) t))
   #'beginning-of-buffer))

(defun kubel-jump-to-previous-highlight ()
  "Jump to the previou highlighted resrouce."
  (interactive)
  (kubel--jump-to-highlight
   #'beginning-of-line
   (lambda () (re-search-backward kubel-resource-filter (point-min) t))
   #'end-of-buffer))

(defun kubel-rollout-history ()
  "See rollout history for resource under cursor."
  (interactive)
  (kubel--show-rollout-revision kubel-resource (kubel--get-resource-under-cursor)))

(defun kubel-changelog ()
  "Opens up the changelog."
  (interactive)
  (browse-url "https://github.com/abrochard/kubel/blob/master/CHANGELOG.md"))

(defun kubel-quick-edit ()
  "Quickly edit any resource."
  (interactive)
  (kubel--describe-resource
   (completing-read "Select resource: " (kubel--kubernetes-resources-list))))

(defun kubel-show-process-buffer ()
  "Show the kubel-process-buffer."
  (interactive)
  (with-current-buffer (get-buffer-create kubel--process-buffer)
    (special-mode))
  (select-window
   (display-buffer kubel--process-buffer
                   '(display-buffer-below-selected
                     (window-height . 0.4)))))

(defun kubel-mark-item ()
  "Mark the item under cursor and move to next line."
  (interactive)
  (let ((item (or (tabulated-list-get-id) (user-error "No resource at point")))
        (col (current-column)))
    (unless (-contains? kubel--selected-items item)
      (push item kubel--selected-items)
      (forward-line 1)
      (move-to-column col)
      (tabulated-list-print t))))

(defun kubel-unmark-item ()
  "Unmark the item under cursor and move to next line."
  (interactive)
  (let ((item (or (tabulated-list-get-id) (user-error "No resource at point")))
        (col (current-column)))
    (when (-contains? kubel--selected-items item)
      (setq kubel--selected-items (delete item kubel--selected-items))
      (forward-line 1)
      (move-to-column col)
      (tabulated-list-print t))))

(defun kubel-mark-all ()
  "Mark all items."
  (interactive)
  (setq kubel--selected-items '())
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (tabulated-list-get-id)
        (push (tabulated-list-get-id) kubel--selected-items))
      (forward-line 1)))
  (tabulated-list-print t))

(defun kubel-unmark-all ()
  "Unmark all items."
  (interactive)
  (setq kubel--selected-items '())
  (tabulated-list-print t))

(defun kubel--read-buffer ()
  "Return the list of all buffers of kubel pattern."
  (let* ((other-buffer (other-buffer (current-buffer)))
         (other-name (buffer-name other-buffer))
         (buffers))
    (dolist (buf (buffer-list))
      (when (string-prefix-p "*kubel:" (buffer-name buf))
        (push buf buffers)))
    (let ((predicate
           (lambda (buffer)
             ;; BUFFER is an entry (BUF-NAME . BUF-OBJ) of Vbuffer_alist.
             (memq (cdr buffer) buffers))))
      (read-buffer
       "Switch to buffer: "
       (when (funcall predicate (cons other-name other-buffer)) other-name)
       nil
       predicate))))

(defun kubel-switch-to-buffer (buffer-or-name)
  "Display buffer BUFFER-OR-NAME in the selected window.
When called interactively, prompts for a buffer belonging to kubel."
  (interactive (list (kubel--read-buffer)))
  (switch-to-buffer buffer-or-name))

;; popups

(transient-define-prefix kubel-exec-popup ()
  "Kubel Exec Menu"
  ["Actions"
   ("!" "Shell command" kubel-exec-pod-by-shell-command)
   ("d" "Dired" kubel-exec-pod)
   ("e" "Eshell" kubel-exec-eshell-pod)
   ("a" "Ansi-term" kubel-exec-ansi-term-pod)
   ("t" "eat" kubel-exec-eat-pod)
   ("s" "Shell" kubel-exec-shell-pod)])

(transient-define-prefix kubel-log-popup ()
  "Kubel Log Menu"
  ["Arguments"
   ("-f" "Follow" "-f")
   ("-p" "Previous" "-p")
   ("-n" "Tail" "--tail=")]
  ["Actions"
   ("l" "Tail pod logs" kubel-get-pod-logs)
   ("i" "Tail initContainer logs" kubel-get-pod-logs--initContainer)
   ("L" "Tail by labels" kubel-get-logs-by-labels)])

(transient-define-prefix kubel-copy-popup ()
  "Kubel Copy Menu"
  ["Actions"
   ("c" "Copy resource name" kubel-copy-resource-name)
   ("l" "Copy pod log command" kubel-copy-log-command)
   ("p" "Copy command prefix" kubel-copy-command-prefix)
   ("C" "Copy last command" kubel-copy-last-command)])

(transient-define-prefix kubel-delete-popup ()
  "Kubel Delete menu"
  ["Arguments"
   ("-f" "Force" "--force --grace-period=0")]
  ["Actions"
   ("k" "Delete resource(s)" kubel-delete-resource)])

(transient-define-prefix kubel-describe-popup ()
  "Kubel Describe Menu"
  ["Arguments"
   ("-y" "Yaml" "-o yaml")]
  ["Actions"
   ("RET" "Describe" kubel-get-resource-details)])

(transient-define-prefix kubel-help-popup ()
  "Kubel Menu"
  [["Actions"
    ;; global
    ("RET" "Resource details" kubel-describe-popup)
    ("E" "Quick edit" kubel-quick-edit)
    ("g" "Refresh" kubel-refresh)
    ("G" "Auto refresh" kubel-auto-refresh-mode)
    ("A" "All namespaces" kubel-toggle-all-namespaces)
    ("b" "Buffers" kubel-switch-to-buffer)
    ("k" "Delete" kubel-delete-popup)
    ("r" "Rollout" kubel-rollout-history)]
   ["" ;; based on current view
    ("p" "Port forward" kubel-port-forward-pod)
    ("l" "Logs" kubel-log-popup)
    ("e" "Exec" kubel-exec-popup)
    ("j" "Restart deployment" kubel-restart-deployment)
    ("S" "Scale replicas" kubel-scale-replicas)]
   ["Settings"
    ("C" "Set context" kubel-set-context)
    ("n" "Set namespace" kubel-set-namespace)
    ("y" "List namespaces" kubel-list-namespaces)
    ("R" "Set resource" kubel-set-resource)
    ("K" "Set kubectl config file" kubel-set-kubectl-config-file)
    ("F" "Set output format" kubel-set-output-format)]
   ["Filter"
    ("f" "Filter" kubel-set-filter)
    ("M-n" "Next highlight" kubel-jump-to-next-highlight)
    ("M-p" "Previous highlight" kubel-jump-to-previous-highlight)
    ("s" "Set label selector" kubel-set-label-selector)]
   ["Marking"
    ("m" "Mark item" kubel-mark-item)
    ("u" "Unmark item" kubel-unmark-item)
    ("M" "Mark all items" kubel-mark-all)
    ("U" "Unmark all items" kubel-unmark-all)]
   ["Utilities"
    ("c" "Copy to clipboad..." kubel-copy-popup)
    ("$" "Show Process buffer" kubel-show-process-buffer)]])

;; mode map
(defvar kubel-mode-map
  (let ((map (make-sparse-keymap)))
    ;; global
    (define-key map (kbd "RET") 'kubel-get-resource-details)
    (define-key map (kbd "K") 'kubel-set-kubectl-config-file)
    (define-key map (kbd "C") 'kubel-set-context)
    (define-key map (kbd "n") 'kubel-set-namespace)
    (define-key map (kbd "y") 'kubel-list-namespaces)
    (define-key map (kbd "g") 'kubel-refresh)
    (define-key map (kbd "C-c C-r") 'kubel-auto-refresh-mode)
    (define-key map (kbd "C-c C-a") 'kubel-toggle-all-namespaces)
    (define-key map (kbd "h") 'kubel-help-popup)
    (define-key map (kbd "?") 'kubel-help-popup)
    (define-key map (kbd "F") 'kubel-set-output-format)
    (define-key map (kbd "R") 'kubel-set-resource)
    (define-key map (kbd "k") 'kubel-delete-popup)
    (define-key map (kbd "f") 'kubel-set-filter)
    (define-key map (kbd "r") 'kubel-rollout-history)
    (define-key map (kbd "E") 'kubel-quick-edit)
    (define-key map (kbd "M-n") 'kubel-jump-to-next-highlight)
    (define-key map (kbd "M-p") 'kubel-jump-to-previous-highlight)
    (define-key map (kbd "$") 'kubel-show-process-buffer)
    (define-key map (kbd "s") 'kubel-set-label-selector)
    (define-key map (kbd "b") 'kubel-switch-to-buffer)
    ;; based on view
    (define-key map (kbd "p") 'kubel-port-forward-pod)
    (define-key map (kbd "S") 'kubel-scale-replicas)
    (define-key map (kbd "l") 'kubel-log-popup)
    (define-key map (kbd "c") 'kubel-copy-popup)
    (define-key map (kbd "e") 'kubel-exec-popup)
    (define-key map (kbd "!") 'kubel-exec-pod-by-shell-command)
    (define-key map (kbd "j") 'kubel-restart-deployment)

    (define-key map (kbd "m") 'kubel-mark-item)
    (define-key map (kbd "u") 'kubel-unmark-item)
    (define-key map (kbd "M") 'kubel-mark-all)
    (define-key map (kbd "U") 'kubel-unmark-all)

    (define-key map (kbd "q") 'kubel-go-back)
    (define-key map (kbd "Q") 'kubel-kill-all-buffers)

    map)
  "Keymap for `kubel-mode'.")

(defcustom kubel-auto-refresh-interval 1
  "Seconds to wait after a resource-list request completes before refreshing.
Only visible buffers refresh, and requests never overlap."
  :type 'number
  :group 'kubel)

(defvar-local kubel-auto-refresh-mode nil)

(defvar-local kubel--auto-refresh-timer nil
  "Timer for this buffer's automatic refreshes.")

(defun kubel--stop-auto-refresh ()
  "Stop this buffer's automatic refresh timer."
  (when (timerp kubel--auto-refresh-timer)
    (cancel-timer kubel--auto-refresh-timer))
  (setq kubel--auto-refresh-timer nil))

(defun kubel--disable-auto-refresh ()
  "Disable automatic refresh before this buffer is killed or changes mode."
  (setq kubel-auto-refresh-mode nil)
  (kubel--stop-auto-refresh))

(defun kubel--schedule-auto-refresh ()
  "Schedule one refresh after the configured delay, unless a request is active."
  (kubel--stop-auto-refresh)
  (when (and kubel-auto-refresh-mode
             (derived-mode-p 'kubel-mode)
             (not (process-live-p kubel--refresh-process)))
    (setq kubel--auto-refresh-timer
          (run-at-time kubel-auto-refresh-interval nil
                       #'kubel--auto-refresh-tick (current-buffer)))))

(defun kubel--auto-refresh-tick (buffer)
  "Refresh BUFFER when visible and no request is pending."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kubel--auto-refresh-timer nil)
      (when (and kubel-auto-refresh-mode (derived-mode-p 'kubel-mode))
        (if (and (get-buffer-window buffer t)
                 (not (process-live-p kubel--refresh-process)))
            (let ((inhibit-message t))
              (kubel-refresh nil t))
          (kubel--schedule-auto-refresh))))))

(define-minor-mode kubel-auto-refresh-mode
  "Automatically refresh this resource buffer while it is visible.
Wait `kubel-auto-refresh-interval' seconds after each completed request
before starting another.  An initial request already in progress is allowed
to finish first."
  :lighter " Auto"
  :group 'kubel
  (kubel--stop-auto-refresh)
  (when kubel-auto-refresh-mode
    (unless (derived-mode-p 'kubel-mode)
      (setq kubel-auto-refresh-mode nil)
      (user-error "Auto refresh requires a kubel resource buffer"))
    (unless (and (numberp kubel-auto-refresh-interval)
                 (> kubel-auto-refresh-interval 0))
      (setq kubel-auto-refresh-mode nil)
      (user-error "Auto refresh interval must be positive"))
    (add-hook 'kill-buffer-hook #'kubel--disable-auto-refresh nil t)
    (add-hook 'change-major-mode-hook #'kubel--disable-auto-refresh nil t)
    (kubel--schedule-auto-refresh)))

(defun kubel-toggle-all-namespaces ()
  "Toggle listing resources across all namespaces in this buffer."
  (interactive)
  (setq kubel-all-namespaces (not kubel-all-namespaces)
        kubel--selected-items nil)
  (kubel-refresh))

(defun kubel--after-clone ()
  "Give cloned sessions independent process and timer state."
  (when (eq header-line-format kubel--activity-header-line)
    (setq header-line-format kubel--activity-saved-header))
  (setq kubel--resource-prompt-token nil
        kubel--namespace-prompt-token nil
        kubel--activity-saved-header nil
        kubel--refresh-process nil
        kubel--activity-processes nil
        kubel--activity-timer nil
        kubel--auto-refresh-timer nil
        kubel-auto-refresh-mode nil
        kubel--error-overlay nil
        kubel--header-error nil
        kubel--selected-items nil))

(defun kubel--current-state ()
  "Show in the Echo Area the current context, namespace, and resource."
  (message (concat
            (format "[Context: %s] [Namespace: %s] [Resource: %s]"
                    kubel-context (if kubel-all-namespaces "all" kubel-namespace) kubel-resource)
            (unless (equal kubel-selector "")
              (format " (%s)" kubel-selector)))))

;;;###autoload
(defun kubel-refresh (&optional directory quiet)
  "Refresh the current kubel buffer, calling kubectl using the configured
context, namespace, and resource asynchronously.
Keep the current table visible until the request succeeds.
QUIET suppresses completion messages for automatic refreshes.

DIRECTORY is optional for TRAMP support."
  (interactive)
  (kubel--clear-header-error)
  (when directory (setq default-directory directory))
  (let ((name (kubel--buffer-name)))
    ;; Remove old buffer if exist but not is current buffer
    (if (get-buffer name)
        (unless (equal (buffer-name (current-buffer)) name)
          (kill-buffer (get-buffer name))))
    (rename-buffer name)
    (message (format "Running kubectl for: %s..." name)))
  (if kubel-context
      (kubel--request
       (append (list kubel-kubectl) (kubel--get-context-namespace t)
               (kubel--get-selector) (list "get" kubel-resource)
               (when kubel-list-wide '("-o" "wide")))
       (lambda (body)
         (let ((inhibit-message quiet)) (kubel--render-list body))))
    (kubel--init-context (lambda () (kubel-refresh nil quiet)))))

;;;###autoload
(defun kubel-open (context namespace resource &optional directory)
  "Create a new kubel buffer using passed parameters CONTEXT NAMESPACE RESOURCE.
DIRECTORY is optional for TRAMP support."
  (let ((tmpname "*kubel-tmp*")
        (name (kubel--buffer-name-from-parameters context namespace resource)))
    (if (get-buffer name)
        (pop-to-buffer-same-window name)
      (with-current-buffer (get-buffer-create tmpname)
        (kubel-mode)
        (setq kubel-context context)
        (setq kubel-namespace namespace)
        (setq kubel-resource resource)
        (pop-to-buffer-same-window tmpname)
        (kubel-refresh directory)))))

(defun kubel--init-context (callback)
  "Initialize context asynchronously, then call CALLBACK."
  (kubel--request
   (list kubel-kubectl "config" "current-context")
   (lambda (output)
     (let ((context (string-trim output)))
       (if (string-empty-p context)
           (kubel--set-header-error "No current context configured")
         (setq kubel-context context)
         (funcall callback))))))

;;;###autoload
(defun kubel (&optional directory)
  "Invoke the kubel buffer.
DIRECTORY is optional for TRAMP support."
  (interactive)
  (let* ((name (kubel--buffer-name))
         (buf (or (get-buffer name)
                  (get-buffer-create name))))
    (with-current-buffer buf
      (switch-to-buffer (current-buffer))
      (unless (eq major-mode 'kubel-mode)
        (kubel-mode))
      (kubel-refresh directory))))

(define-derived-mode kubel-mode tabulated-list-mode "Kubel"
  "Special mode for kubel buffers."
  (buffer-disable-undo)
  (kill-all-local-variables)
  (setq truncate-lines t)
  (setq mode-name "Kubel")
  (setq major-mode 'kubel-mode)
  (setq-local tabulated-list-printer #'kubel--print-entry)
  (use-local-map kubel-mode-map)
  (hl-line-mode 1)
  (add-hook 'clone-buffer-hook #'kubel--after-clone nil t)
  (run-mode-hooks 'kubel-mode-hook))

(provide 'kubel)
;;; kubel.el ends here
