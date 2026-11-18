;;; kubel-evil-test.el --- Evil keybinding tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Check effective bindings, including the underlying kubel major-mode map.

;;; Code:

(require 'ert)
(require 'kubel-evil)

(ert-deftest kubel-evil--test-preserves-motions-and-exposes-actions ()
  "Kubel actions must not override the requested Evil navigation bindings."
  (let ((was-enabled evil-mode))
    (unwind-protect
        (progn
          (evil-mode 1)
          (with-temp-buffer
            (kubel-mode)
            (evil-motion-state)
            (should (eq (key-binding (kbd "e")) #'evil-forward-word-end))
            (should (eq (key-binding (kbd "E")) #'evil-forward-WORD-end))
            (should (eq (key-binding (kbd "$")) #'evil-end-of-line))
            (should (eq (key-binding (kbd "G")) #'evil-goto-line))
            (should (keymapp (key-binding (kbd "g"))))
            (should (eq (key-binding (kbd "gg")) #'evil-goto-first-line))
            (should (eq (key-binding (kbd "gt")) #'tab-bar-switch-to-next-tab))
            (should (eq (key-binding (kbd "gT")) #'tab-bar-switch-to-prev-tab))
            (dolist (binding '(("x" . kubel-exec-popup)
                               ("X" . kubel-quick-edit)
                               ("q" . kill-current-buffer)
                               ("C-c C-g" . kubel-refresh)
                               ("C-c C-p" . kubel-show-process-buffer)
                               ("C-c C-r" . kubel-auto-refresh-mode)
                               ("C-c C-a" . kubel-toggle-all-namespaces)))
              (should (eq (key-binding (kbd (car binding))) (cdr binding))))))
      (unless was-enabled (evil-mode -1)))))

(provide 'kubel-evil-test)
;;; kubel-evil-test.el ends here
