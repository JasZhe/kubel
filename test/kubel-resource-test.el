;;; kubel-resource-test.el --- API resource cache tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Use local shell processes to test discovery without running kubectl.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kubel)

(defmacro kubel-resource-test--with-session (&rest body)
  "Evaluate BODY in an isolated resource completion session."
  (declare (indent 0))
  `(save-window-excursion
     (with-temp-buffer
       (kubel-mode)
       (setq kubel-context "ctx" kubel-resource "pods")
       (let ((kubel-kubectl "kubectl")
             (kubel--resource-cache (make-hash-table :test #'equal))
             (kubel--namespace-cache (make-hash-table :test #'equal))
             (kubel-resource-history '("deployments"))
             (kubel-resource-cache-ttl 300)
             (kubel-resource-cache-retry-delay 30)
             (kubel-resource-request-timeout "30s"))
         (cl-letf (((symbol-function 'kubel--exec-sync)
                    (lambda (&rest _) (error "Unexpected synchronous discovery"))))
           ,@body)))))

(defmacro kubel-resource-test--mock-command (handler &rest body)
  "Use HANDLER to supply a local shell script instead of kubectl in BODY."
  (declare (indent 1))
  (let ((original (make-symbol "make-process")))
    `(let ((,original (symbol-function 'make-process)))
       (cl-letf (((symbol-function 'make-process)
                  (lambda (&rest args)
                    (apply ,original
                           (plist-put args :command
                                      (list "sh" "-c" (funcall ,handler (plist-get args :command))))))))
         ,@body))))

(defun kubel-resource-test--wait (entry)
  "Wait up to three seconds for ENTRY's discovery and deferred callbacks."
  (let ((deadline (+ (float-time) 3)))
    (while (and (process-live-p (kubel--resource-entry-process entry))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (accept-process-output nil 0.03)
    (should-not (process-live-p (kubel--resource-entry-process entry)))))

(ert-deftest kubel-resource--test-cold-selection-opens-before-discovery ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry)) command chosen)
      (kubel-resource-test--mock-command
          (lambda (args) (setq command args) "sleep 0.05; printf 'widgets.example.com\\npods\\n'")
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt candidates &rest _)
                     (should (equal candidates '("deployments" "pods")))
                     (should (process-live-p (kubel--resource-entry-process entry)))
                     "typed.example.com"))
                  ((symbol-function 'kubel--open-resource)
                   (lambda (name) (setq chosen name))))
          (kubel-set-resource)
          (should (equal chosen "typed.example.com"))
          (kubel-resource-test--wait entry)
          (should (equal command '("kubectl" "--context" "ctx" "--request-timeout=30s"
                                   "api-resources" "-o" "name" "--no-headers=true")))
          (should (equal (kubel--resource-entry-names entry) '("pods" "widgets.example.com"))))))))

(ert-deftest kubel-resource--test-fresh-cache-never-starts-discovery ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry)))
      (setf (kubel--resource-entry-names entry) '("widgets.example.com")
            (kubel--resource-entry-fetched-at entry) (float-time))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "Unexpected discovery request"))))
        (should (member "widgets.example.com" (kubel--kubernetes-resources-list)))))))

(ert-deftest kubel-resource--test-expired-cache-refreshes-without-changing-candidates ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry)))
      (setf (kubel--resource-entry-names entry) '("old.example.com")
            (kubel--resource-entry-fetched-at entry) (- (float-time) 301))
      (kubel-resource-test--mock-command (lambda (_) "printf 'new.example.com pods pods'")
        (let ((candidates (kubel--kubernetes-resources-list)))
          (should (member "old.example.com" candidates))
          (kubel-resource-test--wait entry)
          (should (member "old.example.com" candidates))
          (should-not (member "new.example.com" candidates))
          (should (equal (kubel--resource-entry-names entry) '("new.example.com" "pods"))))))))

(ert-deftest kubel-resource--test-prefix-waits-and-leaves-other-caches-intact ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry))
          (namespaces (kubel--namespace-entry)) prompted)
      (setf (kubel--resource-entry-names entry) '("old")
            (kubel--resource-entry-fetched-at entry) (float-time)
            (kubel--resource-entry-retry-after entry) (+ (float-time) 100)
            (kubel--namespace-entry-names namespaces) '("team-a"))
      (setq kubel--label-values-cached '("app=foo"))
      (kubel-resource-test--mock-command (lambda (_) "sleep 0.05; printf fresh")
        (cl-letf (((symbol-function 'kubel--prompt-resource)
                   (lambda (candidates) (setq prompted candidates))))
          (kubel-set-resource t)
          (should-not prompted)
          (kubel-resource-test--wait entry)
          (should (member "fresh" prompted))
          (should-not (member "old" prompted))
          (should (equal (kubel--namespace-entry-names namespaces) '("team-a")))
          (should (equal kubel--label-values-cached '("app=foo"))))))))

(ert-deftest kubel-resource--test-errors-retain-cache-throttle-and-allow-forcing ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry)) (commands 0) prompted)
      (setf (kubel--resource-entry-names entry) '("old"))
      (kubel-resource-test--mock-command
          (lambda (_) (setq commands (1+ commands)) "printf timeout >&2; exit 1")
        (kubel--kubernetes-resources-list)
        (kubel-resource-test--wait entry)
        (should (equal (kubel--resource-entry-names entry) '("old")))
        (should-not (kubel--resource-entry-fetched-at entry))
        (kubel--kubernetes-resources-list)
        (should (= commands 1))
        (cl-letf (((symbol-function 'kubel--prompt-resource)
                   (lambda (candidates) (setq prompted candidates))))
          (kubel-set-resource t)
          (kubel-resource-test--wait entry)
          (should (= commands 2))
          (should (member "old" prompted)))))))

(ert-deftest kubel-resource--test-concurrent-callers-share-one-request ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry)) (commands 0) (callbacks 0))
      (kubel-resource-test--mock-command
          (lambda (_) (setq commands (1+ commands)) "sleep 0.05; printf shared")
        (kubel--refresh-resource-cache t (lambda () (setq callbacks (1+ callbacks))))
        (with-temp-buffer
          (kubel-mode)
          (setq kubel-context "ctx")
          (should (eq entry (kubel--resource-entry)))
          (kubel--refresh-resource-cache t (lambda () (setq callbacks (1+ callbacks)))))
        (should (= commands 1))
        (kubel-resource-test--wait entry)
        (should (= callbacks 2))))))

(ert-deftest kubel-resource--test-scope-shares-directories-and-ignores-namespace-policy ()
  (kubel-resource-test--with-session
    (let ((process-environment (copy-sequence process-environment))
          (default-directory "/tmp/first/"))
      (setenv "KUBECONFIG" "/tmp/shared-config")
      (let ((entry (kubel--resource-entry)))
        (let ((default-directory "/tmp/second/")
              (kubel-use-namespace-list 'off)
              (kubel-namespace "other"))
          (should (eq entry (kubel--resource-entry))))
        (let ((kubel-context "other"))
          (should-not (eq entry (kubel--resource-entry))))
        (setenv "KUBECONFIG" "/tmp/different-config")
        (should-not (eq entry (kubel--resource-entry)))))))

(ert-deftest kubel-resource--test-start-failure-and-empty-success ()
  (kubel-resource-test--with-session
    (let ((entry (kubel--resource-entry)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "Executable unavailable"))))
        (kubel--refresh-resource-cache)
        (should-not (kubel--resource-entry-process entry))
        (should (> (kubel--resource-entry-retry-after entry) (float-time))))
      (kubel-resource-test--mock-command (lambda (_) "true")
        (kubel--refresh-resource-cache t)
        (kubel-resource-test--wait entry)
        (should-not (kubel--resource-entry-names entry))
        (should (kubel--resource-entry-fetched-at entry))
        (should-not (kubel--resource-entry-retry-after entry))))))

(ert-deftest kubel-resource--test-prompts-wait-and-discard-stale-selections ()
  (kubel-resource-test--with-session
    (let ((origin (current-buffer)) (key (kubel--completion-cache-key))
          (token (list 'prompt)) pending prompted)
      (setq kubel--resource-prompt-token token)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
                ((symbol-function 'run-at-time)
                 (lambda (_delay _repeat function &rest args)
                   (setq pending (cons function args))))
                ((symbol-function 'kubel--prompt-resource)
                 (lambda (_) (setq prompted t))))
        (kubel--resource-prompt-ready origin key token)
        (should-not prompted)
        (should pending)
        (setq kubel--resource-prompt-token (list 'newer))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
          (apply (car pending) (cdr pending))
          (should-not prompted)
          (setq kubel--resource-prompt-token token kubel-context "changed")
          (kubel--resource-prompt-ready origin key token)
          (should-not prompted))))))

(ert-deftest kubel-resource--test-opening-view-clones-and-preserves-settings ()
  (kubel-resource-test--with-session
    (setq kubel-all-namespaces t kubel-selector "app=foo")
    (let ((origin (current-buffer)) clone refreshed)
      (unwind-protect
          (cl-letf (((symbol-function 'kubel-refresh)
                     (lambda (&rest _) (setq refreshed t))))
            (kubel--open-resource "widgets.example.com")
            (setq clone (window-buffer (selected-window)))
            (should-not (eq origin clone))
            (with-current-buffer clone
              (should (equal kubel-resource "widgets.example.com"))
              (should (eq kubel--parent-buffer origin))
              (should kubel-all-namespaces)
              (should (equal kubel-selector "app=foo"))
              (should-not kubel-auto-refresh-mode))
            (should refreshed)
            (should (member "widgets.example.com" kubel-resource-history))
            (with-current-buffer origin (should (equal kubel-resource "pods"))))
        (when (buffer-live-p clone) (kill-buffer clone))))))

(provide 'kubel-resource-test)
;;; kubel-resource-test.el ends here
