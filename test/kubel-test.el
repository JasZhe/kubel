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

;; (ert "kubel--test-.*")

(provide 'kubel-test)
;;; kubel-test.el ends here
