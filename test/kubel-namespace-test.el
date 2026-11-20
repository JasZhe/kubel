;;; kubel-namespace-test.el --- Namespace cache tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise namespace discovery with local shell processes, never kubectl.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'kubel)

(defmacro kubel-namespace-test--with-session (&rest body)
  "Evaluate BODY in an isolated namespace session."
  (declare (indent 0))
  `(save-window-excursion
     (with-temp-buffer
       (kubel-mode)
       (setq kubel-context "ctx" kubel-namespace "current")
       (let ((kubel-kubectl "kubectl")
             (kubel--namespace-cache (make-hash-table :test #'equal))
             (kubel-use-namespace-list 'auto)
             (kubel-namespace-cache-ttl 300)
             (kubel-namespace-request-timeout "30s")
             (kubel-namespace-cache-retry-delay 30)
             (kubel-namespace-history '("remembered")))
         (cl-letf (((symbol-function 'kubel--exec-sync)
                    (lambda (&rest _) (error "Unexpected synchronous lookup"))))
           ,@body)))))

(defmacro kubel-namespace-test--mock-command (handler &rest body)
  "Use HANDLER to replace command arguments with a local shell script in BODY."
  (declare (indent 1))
  (let ((original (make-symbol "make-process")))
    `(let ((,original (symbol-function 'make-process)))
       (cl-letf (((symbol-function 'make-process)
                  (lambda (&rest args)
                    (let ((script (funcall ,handler (plist-get args :command))))
                      (apply ,original (plist-put args :command (list "sh" "-c" script)))))))
         ,@body))))

(defun kubel-namespace-test--wait (entry)
  "Wait up to three seconds for ENTRY and its deferred callbacks."
  (let ((deadline (+ (float-time) 3)))
    (while (and (process-live-p (kubel--namespace-entry-process entry))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (accept-process-output nil 0.03)
    (should-not (process-live-p (kubel--namespace-entry-process entry)))))

(ert-deftest kubel-namespace--test-fresh-cache-opens-without-requests ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)))
      (setf (kubel--namespace-entry-names entry) '("alpha" "beta")
            (kubel--namespace-entry-fetched-at entry) (float-time))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "Unexpected namespace request"))))
        (should (equal (kubel--list-namespace)
                       '("alpha" "beta" "remembered" "current" "default")))))))

(ert-deftest kubel-namespace--test-cold-cache-populates-asynchronously ()
  (kubel-namespace-test--with-session
    (let (commands)
      (kubel-namespace-test--mock-command
          (lambda (command)
            (push command commands)
            (if (member "auth" command) "sleep 0.05; printf yes"
              "printf 'beta alpha beta'"))
        (should (equal (kubel--list-namespace) '("remembered" "current" "default")))
        (should (= 1 (length commands)))
        (let ((entry (kubel--namespace-entry)))
          (should (process-live-p (kubel--namespace-entry-process entry)))
          (kubel-namespace-test--wait entry)
          (should (equal (kubel--namespace-entry-names entry) '("alpha" "beta")))
          (should (equal (kubel--namespace-entry-permission entry) 'allowed))
          (should (= 2 (length commands)))
          (should (equal (car (last commands))
                         '("kubectl" "--context" "ctx" "--request-timeout=30s" "auth" "can-i" "list" "namespaces")))
          (kubel--list-namespace)
          (should (= 2 (length commands))))))))

(ert-deftest kubel-namespace--test-stale-candidates-stay-usable-during-refresh ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)))
      (setf (kubel--namespace-entry-names entry) '("old")
            (kubel--namespace-entry-fetched-at entry) (- (float-time) 301))
      (kubel-namespace-test--mock-command
          (lambda (command) (if (member "auth" command) "printf yes" "printf new"))
        (let ((candidates (kubel--list-namespace)))
          (should (member "old" candidates))
          (kubel-namespace-test--wait entry)
          (should (member "old" candidates))
          (should-not (member "new" candidates))
          (should (member "new" (kubel--namespace-candidates))))))))

(ert-deftest kubel-namespace--test-force-waits-for-fresh-candidates-only ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)) prompted)
      (setq kubel--kubernetes-resources-list-cached '("pods")
            kubel--label-values-cached '("app=test"))
      (setf (kubel--namespace-entry-names entry) '("old")
            (kubel--namespace-entry-fetched-at entry) (float-time)
            (kubel--namespace-entry-retry-after entry) (+ (float-time) 100))
      (kubel-namespace-test--mock-command
          (lambda (command)
            (if (member "auth" command) "sleep 0.05; printf yes" "printf fresh"))
        (cl-letf (((symbol-function 'kubel--prompt-namespace)
                   (lambda (candidates) (setq prompted candidates))))
          (kubel-set-namespace t)
          (should-not prompted)
          (kubel-namespace-test--wait entry)
          (should (member "fresh" prompted))
          (should-not (member "old" prompted))
          (should (equal kubel--kubernetes-resources-list-cached '("pods")))
          (should (equal kubel--label-values-cached '("app=test"))))))))

(ert-deftest kubel-namespace--test-failure-retains-cache-and-throttles-retries ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)) (commands 0)
          (timestamp (- (float-time) 301)))
      (setq kubel-use-namespace-list 'on)
      (setq entry (kubel--namespace-entry))
      (setf (kubel--namespace-entry-names entry) '("old")
            (kubel--namespace-entry-fetched-at entry) timestamp)
      (kubel-namespace-test--mock-command
          (lambda (_command) (setq commands (1+ commands)) "printf timeout >&2; exit 1")
        (kubel--list-namespace)
        (kubel-namespace-test--wait entry)
        (should (equal (kubel--namespace-entry-names entry) '("old")))
        (should (= (kubel--namespace-entry-fetched-at entry) timestamp))
        (should (> (kubel--namespace-entry-retry-after entry) (float-time)))
        (kubel--list-namespace)
        (should (= commands 1))
        (kubel--refresh-namespace-cache t)
        (kubel-namespace-test--wait entry)
        (should (= commands 2))))))

(ert-deftest kubel-namespace--test-denied-permission-is-cached ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)) (commands 0))
      (kubel-namespace-test--mock-command
          (lambda (_command) (setq commands (1+ commands)) "printf no; exit 1")
        (kubel--list-namespace)
        (kubel-namespace-test--wait entry)
        (should (eq (kubel--namespace-entry-permission entry) 'denied))
        (should (equal (kubel--list-namespace) '("remembered" "current" "default")))
        (should (= commands 1))
        (kubel--refresh-namespace-cache t)
        (kubel-namespace-test--wait entry)
        (should (= commands 2))))))

(ert-deftest kubel-namespace--test-policy-on-and-off ()
  (kubel-namespace-test--with-session
    (let (commands)
      (kubel-namespace-test--mock-command
          (lambda (command) (push command commands) "printf alpha")
        (setq kubel-use-namespace-list 'off)
        (should (equal (kubel--list-namespace) '("remembered" "current" "default")))
        (kubel--refresh-namespace-cache t)
        (should-not commands)
        (setq kubel-use-namespace-list 'on)
        (kubel--list-namespace)
        (kubel-namespace-test--wait (kubel--namespace-entry))
        (should (= 1 (length commands)))
        (should (member "get" (car commands)))))))

(ert-deftest kubel-namespace--test-requests-are-shared-across-sessions ()
  (kubel-namespace-test--with-session
    (let ((origin (current-buffer)) (entry (kubel--namespace-entry))
          (commands 0) (callbacks 0))
      (setq kubel-use-namespace-list 'on
            entry (kubel--namespace-entry))
      (kubel-namespace-test--mock-command
          (lambda (_command) (setq commands (1+ commands)) "sleep 0.05; printf shared")
        (kubel--refresh-namespace-cache t (lambda () (setq callbacks (1+ callbacks))))
        (with-temp-buffer
          (kubel-mode)
          (setq kubel-context "ctx")
          (should (eq entry (kubel--namespace-entry)))
          (kubel--refresh-namespace-cache t (lambda () (setq callbacks (1+ callbacks)))))
        (should (= commands 1))
        (with-current-buffer origin (kubel-namespace-test--wait entry))
        (should (= callbacks 2))
        (should (equal (kubel--namespace-entry-names entry) '("shared")))))))

(ert-deftest kubel-namespace--test-cache-keys-isolate-execution-configurations ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry))
          (process-environment (copy-sequence process-environment)))
      (dolist (binding '((kubel-context . "other")
                         (kubel-kubectl . "other-kubectl")
                         (kubel-use-namespace-list . on)))
        (cl-progv (list (car binding)) (list (cdr binding))
          (should-not (eq entry (kubel--namespace-entry)))))
      (setenv "KUBECONFIG" "/tmp/kubel-test-config")
      (should-not (eq entry (kubel--namespace-entry))))))

(ert-deftest kubel-namespace--test-ttl-boundaries-and-empty-success ()
  (kubel-namespace-test--with-session
    (let ((old (- (float-time) 100000)))
      (let ((kubel-namespace-cache-ttl nil)) (should (kubel--namespace-fresh-p old)))
      (let ((kubel-namespace-cache-ttl 0)) (should-not (kubel--namespace-fresh-p (float-time))))
      (should-not (kubel--namespace-fresh-p nil)))
    (setq kubel-use-namespace-list 'on)
    (let ((entry (kubel--namespace-entry)) (commands 0))
      (kubel-namespace-test--mock-command
          (lambda (_command) (setq commands (1+ commands)) "true")
        (kubel--list-namespace)
        (kubel-namespace-test--wait entry)
        (should (kubel--namespace-entry-fetched-at entry))
        (should-not (kubel--namespace-entry-names entry))
        (kubel--list-namespace)
        (should (= commands 1))))))

(ert-deftest kubel-namespace--test-resource-refresh-and-invalidation-are-independent ()
  (kubel-namespace-test--with-session
    (setq kubel-use-namespace-list 'on)
    (let ((entry (kubel--namespace-entry)))
      (kubel-namespace-test--mock-command
          (lambda (_command) "sleep 0.1; printf alpha")
        (kubel--refresh-namespace-cache)
        (let ((namespaces (kubel--namespace-entry-process entry)))
          (kubel--request '("sh" "-c" "sleep 0.05") #'ignore)
          (should (process-live-p namespaces))
          (kubel--invalidate-context-caches)
          (should (eq entry (kubel--namespace-entry)))
          (kubel-namespace-test--wait entry)
          (should (equal (kubel--namespace-entry-names entry) '("alpha"))))))))

(ert-deftest kubel-namespace--test-stale-prompt-does-not-open ()
  (kubel-namespace-test--with-session
    (let ((origin (current-buffer)) (key (kubel--namespace-cache-key))
          (token (list 'prompt)) prompted)
      (cl-letf (((symbol-function 'kubel--prompt-namespace)
                 (lambda (_) (setq prompted t))))
        (setq kubel--namespace-prompt-token (list 'newer))
        (kubel--namespace-prompt-ready origin key token)
        (should-not prompted)
        (setq kubel--namespace-prompt-token token kubel-context "changed")
        (kubel--namespace-prompt-ready origin key token)
        (should-not prompted)))))

(ert-deftest kubel-namespace--test-normal-selection-opens-before-fetch-completes ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)) chosen)
      (kubel-namespace-test--mock-command
          (lambda (command)
            (if (member "auth" command) "sleep 0.05; printf yes" "printf fetched"))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt candidates &rest _)
                     (should (process-live-p (kubel--namespace-entry-process entry)))
                     (should-not (member "fetched" candidates))
                     "typed-namespace"))
                  ((symbol-function 'kubel--open-namespace)
                   (lambda (namespace) (setq chosen namespace))))
          (kubel-set-namespace)
          (should (equal chosen "typed-namespace"))
          (kubel-namespace-test--wait entry)
          (should (equal (kubel--namespace-entry-names entry) '("fetched"))))))))

(ert-deftest kubel-namespace--test-force-failure-still-opens-cached-candidates ()
  (kubel-namespace-test--with-session
    (setq kubel-use-namespace-list 'on)
    (let ((entry (kubel--namespace-entry)) prompted)
      (setf (kubel--namespace-entry-names entry) '("old"))
      (kubel-namespace-test--mock-command
          (lambda (_) "printf timeout >&2; exit 1")
        (cl-letf (((symbol-function 'kubel--prompt-namespace)
                   (lambda (candidates) (setq prompted candidates))))
          (kubel-set-namespace t)
          (kubel-namespace-test--wait entry)
          (should (member "old" prompted)))))))

(ert-deftest kubel-namespace--test-prompt-waits-for-existing-minibuffer ()
  (kubel-namespace-test--with-session
    (let ((origin (current-buffer)) (key (kubel--namespace-cache-key))
          (token (list 'prompt)) pending prompted)
      (setq kubel--namespace-prompt-token token)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () t))
                ((symbol-function 'run-at-time)
                 (lambda (_delay _repeat function &rest args)
                   (setq pending (cons function args))))
                ((symbol-function 'kubel--prompt-namespace)
                 (lambda (_) (setq prompted t))))
        (kubel--namespace-prompt-ready origin key token)
        (should-not prompted)
        (should pending)
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
          (apply (car pending) (cdr pending))
          (should prompted))))))

(ert-deftest kubel-namespace--test-shared-fetch-survives-origin-buffer-closing ()
  (kubel-namespace-test--with-session
    (let ((source (generate-new-buffer " *kubel-namespace-source*")) entry prompted)
      (unwind-protect
          (kubel-namespace-test--mock-command
              (lambda (command)
                (if (member "auth" command) "sleep 0.05; printf yes" "printf surviving"))
            (cl-letf (((symbol-function 'kubel--prompt-namespace)
                       (lambda (_) (setq prompted t))))
              (with-current-buffer source
                (kubel-mode)
                (setq kubel-context "ctx")
                (setq entry (kubel--namespace-entry))
                (kubel-set-namespace t))
              (kill-buffer source)
              (kubel-namespace-test--wait entry)
              (should-not prompted)
              (should (equal (kubel--namespace-entry-names entry) '("surviving")))))
        (when (buffer-live-p source) (kill-buffer source))))))

(ert-deftest kubel-namespace--test-process-start-failure-retains-data ()
  (kubel-namespace-test--with-session
    (let ((entry (kubel--namespace-entry)))
      (setf (kubel--namespace-entry-names entry) '("old"))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "Executable unavailable"))))
        (kubel--refresh-namespace-cache t)
        (should (equal (kubel--namespace-entry-names entry) '("old")))
        (should-not (kubel--namespace-entry-process entry))
        (should (> (kubel--namespace-entry-retry-after entry) (float-time)))))))

(ert-deftest kubel-namespace--test-local-directories-share-config-cache ()
  (kubel-namespace-test--with-session
    (let ((process-environment (copy-sequence process-environment)))
      (dolist (config (list nil "" "/tmp/shared-config"))
        (setenv "KUBECONFIG" config)
        (let* ((default-directory "/tmp/first/")
               (entry (kubel--namespace-entry)))
          (let ((default-directory "/tmp/second/"))
            (should (eq entry (kubel--namespace-entry))))))
      ;; Explicitly selecting the default config shares its normal cache.
      (setenv "KUBECONFIG" nil)
      (let ((key (kubel--namespace-cache-key)))
        (setenv "KUBECONFIG" (expand-file-name "~/.kube/config"))
        (should (equal key (kubel--namespace-cache-key)))))))

(ert-deftest kubel-namespace--test-relative-configs-resolve-before-caching ()
  (kubel-namespace-test--with-session
    (let ((process-environment (copy-sequence process-environment))
          (default-directory "/tmp/first/"))
      (setenv "KUBECONFIG" "./config")
      (let ((first (kubel--namespace-cache-key)))
        (setenv "KUBECONFIG" "/tmp/first/config")
        (should (equal first (kubel--namespace-cache-key)))
        (setenv "KUBECONFIG" "./config")
        (let ((default-directory "/tmp/second/"))
          (should-not (equal first (kubel--namespace-cache-key)))))
      (setenv "KUBECONFIG" "../shared/config")
      (let ((key (kubel--namespace-cache-key)))
        (let ((default-directory "/tmp/second/"))
          (should (equal key (kubel--namespace-cache-key)))))
      (setenv "KUBECONFIG" "a:../shared/config::a")
      (let ((key (kubel--namespace-cache-key)))
        (setenv "KUBECONFIG" "/tmp/first/a:/tmp/shared/config")
        (should (equal key (kubel--namespace-cache-key)))
        (setenv "KUBECONFIG" "/tmp/shared/config:/tmp/first/a")
        (should-not (equal key (kubel--namespace-cache-key))))
      ;; Tildes in environment values are literal, unlike shell expansion.
      (setenv "KUBECONFIG" "~/config")
      (let ((key (kubel--namespace-cache-key)))
        (setenv "KUBECONFIG" "/tmp/first/~/config")
        (should (equal key (kubel--namespace-cache-key)))))))

(ert-deftest kubel-namespace--test-relative-executables-keep-directory-identity ()
  (kubel-namespace-test--with-session
    (let ((default-directory "/tmp/first/")
          (kubel-kubectl "./bin/kubectl")
          (process-environment (copy-sequence process-environment)))
      (setenv "KUBECONFIG" "/tmp/shared-config")
      (let ((key (kubel--namespace-cache-key)))
        (let ((kubel-kubectl "/tmp/first/bin/kubectl"))
          (should (equal key (kubel--namespace-cache-key))))
        (let ((default-directory "/tmp/second/"))
          (should-not (equal key (kubel--namespace-cache-key))))))))

(ert-deftest kubel-namespace--test-remote-identities-do-not-connect ()
  (kubel-namespace-test--with-session
    (let ((default-directory "/ssh:alice@first:/work/a/")
          (process-environment (copy-sequence process-environment)))
      (setenv "KUBECONFIG" nil)
      (cl-letf (((symbol-function 'tramp-maybe-open-connection)
                 (lambda (&rest _) (error "Unexpected remote connection")))
                ((symbol-function 'file-truename)
                 (lambda (&rest _) (error "Unexpected filesystem access"))))
        (let ((key (kubel--namespace-cache-key)))
          (let ((default-directory "/ssh:alice@first:/work/b/"))
            (should (equal key (kubel--namespace-cache-key))))
          (dolist (default-directory '("/ssh:alice@second:/work/a/"
                                      "/ssh:bob@first:/work/a/"
                                      "/sudo:root@first:/work/a/"
                                      "/tmp/"))
            (should-not (equal key (kubel--namespace-cache-key)))))
        (setenv "KUBECONFIG" "../config")
        (let ((key (kubel--namespace-cache-key)))
          (let ((default-directory "/ssh:alice@first:/work/b/"))
            (should (equal key (kubel--namespace-cache-key))))
          (setenv "KUBECONFIG" "/work/config")
          (should (equal key (kubel--namespace-cache-key))))))))

(provide 'kubel-namespace-test)
;;; kubel-namespace-test.el ends here
