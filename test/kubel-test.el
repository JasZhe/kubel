;;; kubel-test.el --- Tests -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-macs)
(require 'kubel)

(ert-deftest kubel--test-extract-value ()
  (let ((line "0123456789"))
    (should (equal "0" (kubel--extract-value line 0 1)))
    (should (equal "0123" (kubel--extract-value line 0 4)))
    (should (equal "34567" (kubel--extract-value line 3 8)))
    (should (equal "56789" (kubel--extract-value line 5 "end")))
    (should (equal "-" (kubel--extract-value "     " 0 5)))
    (should (equal "-" (kubel--extract-value "  " 0 "end")))))

(ert-deftest kubel--test-prefix-scopes-selector-to-list-commands ()
  "The label selector must not leak into single-resource commands.

kubectl refuses a resource name combined with `--selector', and `exec'
does not accept `--selector' at all."
  (let ((kubel-kubectl "kubectl")
        (kubel-context "ctx")
        (kubel-namespace "ns")
        (kubel-selector "app=foo"))
    (should (equal "kubectl --context ctx -n ns"
                   (kubel--get-command-prefix)))
    (should (equal "kubectl --context ctx -n ns --selector app=foo"
                   (kubel--get-list-command-prefix)))))

(defun kubel-test--wait (process)
  "Wait up to three seconds for PROCESS and its sentinel."
  (let ((deadline (+ (float-time) 3)))
    (while (and (process-live-p process) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (accept-process-output nil 0.02)
    (should-not (process-live-p process))))

(ert-deftest kubel--test-request-is-asynchronous ()
  "Requests return immediately and finish in the originating buffer."
  (with-temp-buffer
    (kubel-mode)
    (let ((origin (current-buffer))
          (result nil)
          (timer-ran nil))
      (kubel--request '("sh" "-c" "sleep 0.15; printf ready")
                      (lambda (output)
                        (setq result (list (current-buffer) output))))
      (should-not result)
      (should (process-live-p kubel--refresh-process))
      (let ((timer (run-at-time 0.01 nil (lambda () (setq timer-ran t))))
            (process kubel--refresh-process))
        (unwind-protect
            (with-temp-buffer (kubel-test--wait process))
          (cancel-timer timer)))
      (should timer-ran)
      (should (equal result (list origin "ready")))
      (should-not kubel--refresh-process))))

(ert-deftest kubel--test-request-supersedes-old-results ()
  (with-temp-buffer
    (kubel-mode)
    (let ((results nil))
      (kubel--request '("sh" "-c" "sleep 0.15; printf old")
                      (lambda (output) (push output results)))
      (let ((old kubel--refresh-process))
        (kubel--request '("sh" "-c" "printf new")
                        (lambda (output) (push output results)))
        (kubel-test--wait kubel--refresh-process)
        (should-not (process-live-p old))
        (should (equal results '("new")))))))

(ert-deftest kubel--test-request-failure-preserves-table ()
  (with-temp-buffer
    (kubel-mode)
    (setq tabulated-list-entries '(("old" ["old"])))
    (kubel--request '("sh" "-c" "printf forbidden >&2; exit 1")
                    #'kubel--render-list)
    (kubel-test--wait kubel--refresh-process)
    (should (equal tabulated-list-entries '(("old" ["old"]))))
    (should (equal kubel--header-error "forbidden"))))

(ert-deftest kubel--test-request-killed-buffer-cleans-up ()
  (let ((buffer (generate-new-buffer " *kubel-test-origin*"))
        process stdout stderr called)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (kubel-mode)
            (kubel--request '("sh" "-c" "sleep 0.15; printf late")
                            (lambda (_) (setq called t)))
            (setq process kubel--refresh-process
                  stdout (process-buffer process)
                  stderr (get-buffer " *kubel-refresh-stderr*")))
          (kill-buffer buffer)
          (kubel-test--wait process)
          (should-not called)
          (should-not (buffer-live-p stdout))
          (should-not (buffer-live-p stderr)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kubel--test-refresh-builds-command-and-renders ()
  (with-temp-buffer
    (kubel-mode)
    (setq kubel-context "ctx" kubel-namespace "ns"
          kubel-selector "app=foo" kubel-list-wide t)
    (let ((original-make-process (symbol-function 'make-process)) command)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq command (plist-get args :command))
                   (apply original-make-process
                          (plist-put args :command
                                     '("sh" "-c" "printf 'NAME  STATUS\\nfoo   Running\\n'"))))))
        (kubel-refresh)
        (kubel-test--wait kubel--refresh-process))
      (should (equal command
                     (list kubel-kubectl "--context" "ctx" "-n" "ns"
                           "--selector" "app=foo" "get" "pods" "-o" "wide")))
      (should (equal (caar tabulated-list-entries) "foo")))))

(ert-deftest kubel--test-initial-context-is-asynchronous ()
  (with-temp-buffer
    (kubel-mode)
    (setq kubel-kubectl "custom-kubectl")
    (let ((original-make-process (symbol-function 'make-process)) commands)
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (let ((command (plist-get args :command)))
                     (push command commands)
                     (apply original-make-process
                            (plist-put args :command
                                       (if (member "config" command)
                                           '("sh" "-c" "sleep 0.05; printf ctx")
                                         '("sh" "-c" "printf 'NAME  STATUS\\nfoo   Running\\n'"))))))))
        (kubel-refresh)
        (should-not kubel-context)
        (kubel-test--wait kubel--refresh-process)
        (when kubel--refresh-process
          (kubel-test--wait kubel--refresh-process)))
      (should (equal kubel-context "ctx"))
      (should (equal (car (last commands))
                     '("custom-kubectl" "config" "current-context")))
      (should (equal (caar tabulated-list-entries) "foo")))))

(ert-deftest kubel--test-spinner-follows-concurrent-commands ()
  "Finishing one command must not hide another command's indicator."
  (save-window-excursion
    (with-temp-buffer
      (kubel-mode)
      (setq kubel-kubectl "sh" kubel-context nil kubel-namespace "")
      (let* ((origin (current-buffer))
             (first (save-current-buffer
                      (kubel--exec-async "kubel-test-first"
                                         '("-c" "sleep 0.05; printf first"))))
             (second (save-current-buffer
                       (kubel--exec-async "kubel-test-second"
                                          '("-c" "sleep 0.4; printf second")))))
        (unwind-protect
            (progn
              (should (= 2 (length kubel--activity-processes)))
              (should (string-match-p (regexp-quote "(+1)") (kubel--activity-status)))
              (with-current-buffer (process-buffer second)
                (should (equal kubel--activity-processes (list second)))
                (should (timerp kubel--activity-timer)))
              (kubel-test--wait first)
              (with-current-buffer origin
                (should (equal kubel--activity-processes (list second)))
                (should (timerp kubel--activity-timer)))
              (with-current-buffer (process-buffer first)
                (should-not kubel--activity-processes)
                (should-not kubel--activity-timer))
              (let ((frame kubel--activity-frame))
                (kubel-test--wait second)
                (should (> kubel--activity-frame frame)))
              (should-not kubel--activity-processes)
              (should-not kubel--activity-timer)
              (should-not (kubel--activity-status)))
          (dolist (process (list first second))
            (when (process-live-p process) (delete-process process))
            (when (buffer-live-p (process-buffer process))
              (kill-buffer (process-buffer process)))))))))

(ert-deftest kubel--test-spinner-stops-on-failure-and-cancellation ()
  (save-window-excursion
    (dolist (cancel '(nil t))
      (with-temp-buffer
        (kubel-mode)
        (setq kubel-kubectl "sh" kubel-context nil kubel-namespace "")
        (let* ((called nil)
               (process (save-current-buffer
                          (kubel--exec-async
                           "kubel-test-failure"
                           (list "-c" (if cancel "sleep 1" "printf failed >&2; exit 1"))
                           nil (lambda () (setq called t)))))
               (errors (get-buffer (kubel--process-error-buffer "kubel-test-failure"))))
          (when cancel (delete-process process))
          (kubel-test--wait process)
          (should-not called)
          (should-not kubel--activity-processes)
          (should-not kubel--activity-timer)
          (should-not (buffer-live-p errors))
          (with-current-buffer (process-buffer process)
            (should-not kubel--activity-timer)
            (unless cancel (should (equal kubel--header-error "failed"))))
          (kill-buffer (process-buffer process)))))))

(ert-deftest kubel--test-spinner-stops-when-buffer-is-killed ()
  (let ((buffer (generate-new-buffer " *kubel-test-spinner*"))
        process timer)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (kubel-mode)
            (kubel--request '("sh" "-c" "sleep 1") #'ignore)
            (setq process kubel--refresh-process
                  timer kubel--activity-timer)
            (should (timerp timer)))
          (kill-buffer buffer)
          (kubel-test--wait process)
          (should-not (memq timer timer-list)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kubel--test-all-namespaces-identities-and-scopes ()
  "Identical names in different namespaces remain distinct and actionable."
  (with-temp-buffer
    (kubel-mode)
    (setq kubel-context "ctx" kubel-namespace "default" kubel-all-namespaces t)
    (kubel--render-list
     (concat (format "%-12s %-12s %s\n" "NAMESPACE" "NAME" "STATUS")
             (format "%-12s %-12s %s\n" "alpha" "same" "Running")
             (format "%-12s %-12s %s\n" "beta" "same" "Pending")))
    (should (equal (mapcar #'car tabulated-list-entries)
                   '(("alpha" . "same") ("beta" . "same"))))
    (goto-char (point-min))
    (should (equal (kubel--get-resource-under-cursor) "same"))
    (should (equal (kubel--get-context-namespace) '("--context" "ctx" "-n" "alpha")))
    (should (equal (kubel--get-context-namespace t) '("--context" "ctx" "--all-namespaces")))
    (kubel-mark-item)
    (should (equal kubel--selected-items '(("alpha" . "same"))))
    (should (equal (kubel--effective-namespace) "beta"))
    (kubel-mark-item)
    (should (= 2 (length kubel--selected-items)))
    ;; A refresh preserves both marks using the full namespace/name identity.
    (kubel--get-list-entries '(("NAMESPACE" "NAME") ("alpha" "same") ("beta" "same")))
    (should (= 2 (length kubel--selected-items)))
    (kubel--get-list-entries '(("NAMESPACE" "NAME") ("beta" "same")))
    (should (equal kubel--selected-items '(("beta" . "same"))))))

(ert-deftest kubel--test-batch-delete-and-restart-namespace-scoping ()
  "Every marked resource uses its own namespace despite output buffer switches."
  (with-temp-buffer
    (kubel-mode)
    (setq kubel-context "ctx" kubel-namespace "default"
          kubel-all-namespaces t kubel-resource "deployments"
          kubel--selected-items '(("alpha" . "same") ("beta" . "same")))
    (let ((origin (current-buffer)) commands
          (output (generate-new-buffer " *kubel-test-batch-output*")))
      (unwind-protect
          (cl-letf (((symbol-function 'transient-args) (lambda (_) nil))
                    ((symbol-function 'kubel--exec-async)
                     (lambda (_name args &rest _)
                       (push (append (kubel--get-context-namespace) args) commands)
                       (set-buffer output))))
            (kubel-delete-resource)
            (should (equal (nreverse commands)
                           '(("--context" "ctx" "-n" "alpha" "delete" "deployments" "same")
                             ("--context" "ctx" "-n" "beta" "delete" "deployments" "same"))))
            (setq commands nil)
            (set-buffer origin)
            (kubel-restart-deployment)
            (should (equal (nreverse commands)
                           '(("--context" "ctx" "-n" "alpha" "rollout" "restart" "deployment/same")
                             ("--context" "ctx" "-n" "beta" "rollout" "restart" "deployment/same"))))
            (should (eq (indirect-function 'kubel-jab-deployment)
                        (symbol-function 'kubel-restart-deployment))))
        (kill-buffer output)))))

(ert-deftest kubel--test-auto-refresh-delay-starts-after-completion ()
  "Enabling during a slow request waits until completion before starting a delay."
  (with-temp-buffer
    (kubel-mode)
    (let ((kubel-auto-refresh-interval 1)
          (original-run-at-time (symbol-function 'run-at-time))
          completed scheduled)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (delay repeat function &rest args)
                   (when (eq function #'kubel--auto-refresh-tick)
                     (setq scheduled (list (float-time) delay repeat)))
                   (apply original-run-at-time delay repeat function args))))
        (kubel--request '("sh" "-c" "sleep 0.15; printf ready")
                        (lambda (_) (setq completed (float-time))))
        (kubel-auto-refresh-mode 1)
        (should-not kubel--auto-refresh-timer)
        (should-not scheduled)
        (kubel-test--wait kubel--refresh-process)
        (should completed)
        (should (>= (car scheduled) completed))
        (should (equal (cdr scheduled) '(1 nil)))
        (let ((timer kubel--auto-refresh-timer))
          (should (timerp timer))
          ;; Starting another request removes the old timer; completion rearms it.
          (kubel--request '("sh" "-c" "sleep 0.05; printf ready") #'ignore)
          (should-not kubel--auto-refresh-timer)
          (should-not (memq timer timer-list))
          (kubel-test--wait kubel--refresh-process)
          (should (timerp kubel--auto-refresh-timer)))
        (kubel-auto-refresh-mode -1)
        (should-not kubel--auto-refresh-timer)))))

(ert-deftest kubel--test-auto-refresh-tick-visibility-and-overlap ()
  (with-temp-buffer
    (kubel-mode)
    (let ((calls 0) visible)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) visible))
                ((symbol-function 'kubel-refresh)
                 (lambda (&rest _) (setq calls (1+ calls)))))
        (kubel-auto-refresh-mode 1)
        (kubel--stop-auto-refresh)
        (kubel--auto-refresh-tick (current-buffer))
        (should (= calls 0))
        (should (timerp kubel--auto-refresh-timer))
        (kubel--stop-auto-refresh)
        (setq visible t)
        (kubel--auto-refresh-tick (current-buffer))
        (should (= calls 1))
        (kubel--request '("sh" "-c" "sleep 0.15") #'ignore)
        (kubel--auto-refresh-tick (current-buffer))
        (should (= calls 1))
        (should-not kubel--auto-refresh-timer)
        (kubel-test--wait kubel--refresh-process)
        (kubel-auto-refresh-mode -1)))))

(ert-deftest kubel--test-cloned-session-does-not-share-requests-or-timers ()
  (with-temp-buffer
    (kubel-mode)
    (kubel--request '("sh" "-c" "sleep 0.15") #'ignore)
    (kubel-auto-refresh-mode 1)
    (let ((process kubel--refresh-process)
          (activity-timer kubel--activity-timer)
          (clone (clone-buffer)))
      (unwind-protect
          (with-current-buffer clone
            (should-not kubel--refresh-process)
            (should-not kubel--activity-timer)
            (should-not kubel--auto-refresh-timer)
            (should-not kubel-auto-refresh-mode))
        (kill-buffer clone))
      (should (process-live-p process))
      (should (memq activity-timer timer-list))
      (kubel-test--wait process)
      (let ((auto-timer kubel--auto-refresh-timer))
        (should (timerp auto-timer))
        (kubel--stop-auto-refresh)
        (should-not (memq auto-timer timer-list))))))

(ert-deftest kubel--test-auto-refresh-kill-does-not-rearm-timer ()
  "Cancelling an active request during buffer teardown must not leave a timer."
  (let ((buffer (generate-new-buffer " *kubel-test-auto-kill*"))
        (original-run-at-time (symbol-function 'run-at-time))
        process scheduled)
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (delay repeat function &rest args)
                     (when (eq function #'kubel--auto-refresh-tick)
                       (setq scheduled t))
                     (apply original-run-at-time delay repeat function args))))
          (with-current-buffer buffer
            (kubel-mode)
            (kubel--request '("sh" "-c" "sleep 0.15") #'ignore)
            (setq process kubel--refresh-process)
            (kubel-auto-refresh-mode 1))
          (kill-buffer buffer)
          (kubel-test--wait process)
          (should-not scheduled))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest kubel--test-auto-refresh-retries-after-failure ()
  (with-temp-buffer
    (kubel-mode)
    (kubel--request '("sh" "-c" "printf forbidden >&2; exit 1") #'ignore)
    (kubel-auto-refresh-mode 1)
    (kubel-test--wait kubel--refresh-process)
    (should (equal kubel--header-error "forbidden"))
    (should (timerp kubel--auto-refresh-timer))
    (kubel-auto-refresh-mode -1)))

(ert-deftest kubel--test-refresh-spinner-visible-without-mode-line-lighters ()
  "The header shows activity even when the mode line omits minor modes."
  (with-temp-buffer
    (kubel-mode)
    (setq-local mode-line-format '("%b"))
    (setq-local minor-mode-alist nil)
    (setq-local header-line-format "Original columns")
    (kubel--request '("sh" "-c" "sleep 0.15; printf ready") #'ignore)
    (should (eq header-line-format kubel--activity-header-line))
    (should (string-match-p "Loading context" (eval (cadr header-line-format) t)))
    (kubel-test--wait kubel--refresh-process)
    (should (equal header-line-format "Original columns"))
    (should-not kubel--activity-saved-header)))

(ert-deftest kubel--test-spinner-keeps-new-header-set-during-request ()
  "Finishing a command must not overwrite a header changed by another mode."
  (with-temp-buffer
    (kubel-mode)
    (kubel--request '("sh" "-c" "sleep 0.05") #'ignore)
    (setq-local header-line-format "New header")
    (kubel-test--wait kubel--refresh-process)
    (should (equal header-line-format "New header"))))

(ert-deftest kubel--test-auto-refresh-is-local-to-enabled-buffer ()
  "Only the enabled buffer refreshes, even when another buffer is current."
  (let ((first (generate-new-buffer " *kubel-test-auto-first*"))
        (second (generate-new-buffer " *kubel-test-auto-second*"))
        (kubel-auto-refresh-interval 0.05)
        calls)
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) t))
                  ((symbol-function 'kubel-refresh)
                   (lambda (&rest _) (push (current-buffer) calls))))
          (with-current-buffer first
            (kubel-mode)
            (kubel-auto-refresh-mode 1))
          (with-current-buffer second
            (kubel-mode)
            (should-not kubel-auto-refresh-mode)
            (should-not kubel--auto-refresh-timer)
            (kubel--auto-refresh-tick second)
            (let ((deadline (+ (float-time) 2)))
              (while (and (null calls) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should (equal calls (list first)))
            (should-not kubel-auto-refresh-mode)
            ;; Enabling the second buffer creates its own timer; disabling
            ;; the first buffer must not cancel it.
            (kubel-auto-refresh-mode 1)
            (let ((timer kubel--auto-refresh-timer))
              (with-current-buffer first (kubel-auto-refresh-mode -1))
              (should (eq timer kubel--auto-refresh-timer))
              (should (memq timer timer-list)))
            (let ((deadline (+ (float-time) 2)))
              (while (and (= (length calls) 1) (< (float-time) deadline))
                (accept-process-output nil 0.02)))
            (should (equal calls (list second first)))))
      (kill-buffer first)
      (kill-buffer second))))

;; (ert "kubel--test-.*")

(provide 'kubel-test)
;;; kubel-test.el ends here
