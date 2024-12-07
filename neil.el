;;; neil.el --- companion for Babashka Neil -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2021 - 2022 Michiel Borkent
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: April 20, 2022
;; Modified: May 01, 2024
;; Version: 0.0.1
;; Keywords: convenience tools
;; Homepage: https://github.com/babashka/neil
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; neil.el is a helper package for babashka/neil. It requires neil command-line utility
;; installed and available in the PATH, see: https://github.com/babashka/neil#installation.

;;; Code:

(require 'seq)
(require 'subr-x)

(defcustom neil-prompt-for-version-p t
  "When non-nil, select from available versions of a lib.
Otherwise, use the latest found."
  :type 'boolean
  :group 'neil)

(defcustom neil-inject-dep-to-project-p nil
  "When non-til, try to add library dependency to current project.
Otherwise, simply store the dependency string in the `kill-ring'.
Works only for deps.edn projects."
  :type 'boolean
  :group 'neil)

(defcustom neil-executable-path nil
  "If nil, tries to find neil executable in the PATH.
Otherwise uses the given value."
  :type 'string
  :group 'neil)

(defcustom neil-after-find-clojure-package-hook nil
  "Runs after successfully resolving dependency.
Hook function takes a single parameter:
lib coords string - typically like: \"cheshire/cheshire {:mvn/version \"5.13.0\"}\"."
  :type 'string
  :group 'neil)

(defun neil--identify-project-build-tool ()
  "Find build tools used in the project."
  (let* ((default-directory (or (when (fboundp 'projectile-project-root)
                                  (funcall #'projectile-project-root))
                                (when (fboundp 'clojure-project-dir)
                                  (funcall #'clojure-project-dir))))
         (build-files '((clojure-cli . "deps.edn")
                        (lein . "project.clj")
                        (boot . "build.boot")
                        (shadow-cljs . "shadow-cljs.edn"))))
    (delq nil
          (mapcar (lambda (candidate)
                    (when (file-exists-p (cdr candidate))
                      (car candidate)))
                  build-files))))

(defun neil-search-annotation-fn (s)
  "Annotate dependency S with its version."
  (let-alist (cdr (assoc s minibuffer-completion-table))
    (concat "   " .version "    " .description)))

(defun neil-cider-load-lib (coords)
  "Hot-load a Clojure lib NAME into current cider session.
COORDS must be lib coords string, something
like: \"cheshire/cheshire {:mvn/version \"5.13.0\"}\"."
  ;; fbound checks are intentionally verbose to avoid issues with Flycheck and
  ;; to ensure the package does not depend on CIDER.
  (cond
   ((not (fboundp 'cider))
    (message "CIDER not installed"))
   ((not (and (fboundp 'cider-connected-p) (cider-connected-p)))
    (message "CIDER not connected"))
   ((not (and (fboundp 'cider-project-type)
              (eq 'clojure-cli (cider-project-type))))
    (message "Has to be deps.edn project for hot-loading"))
   ((not (and (fboundp 'cider--clojure-version)
              (version< "1.12.0-alpha2" (cider--clojure-version))))
    (message "You need at least 1.12.0-alpha2 of Clojure for hot-loading dependencies"))
   ((and (fboundp 'nrepl-dict-get)
         (fboundp 'cider-sync-tooling-eval)
         (fboundp 'cider--clojure-version))
      (when-let* ((clj-form (format "(add-libs '{%s})" coords))
                  (msg (nrepl-dict-get (cider-sync-tooling-eval clj-form) "value")))
        (with-temp-message "loaded: %s" msg)
        nil))))

;;;###autoload
(defun neil-find-clojure-package (&optional term)
  "Find Clojure dependency by supplying TERM to neil cmd-line tool.
When `neil-prompt-for-version-p' is t - after selecting library
name lets you choose its version.
With `neil-inject-dep-to-project-p' set to t, automatically adds
the dependency to the project (deps.edn only)."
  (interactive
   (list (read-from-minibuffer
          "Search for Clojure libs: "
          (when (member (file-name-nondirectory (or (buffer-file-name) ""))
                        '("deps.edn" "project.clj"))
            (when-let ((sym (symbol-at-point)))
              (symbol-name sym))))))
  (let* ((format-dep-str
          (lambda (lib-name version)
            (let ((build-tool (car (neil--identify-project-build-tool))))
              (when (and lib-name version)
                (if (or (null build-tool)
                        (eq build-tool 'clojure-cli))
                    (format "%s {:mvn/version %S}"
                            lib-name version)
                  (format "[%s %S]" lib-name version))))))

         (perform-action
          (lambda (exe args)
            (let* ((res (shell-command-to-string
                         (format "%s %s" exe args)))
                   (res (if (or (string-match-p "Usage: neil dep search" res)
                                (and (string-match-p "Unable to find.*Maven" res)
                                     (string-match-p "Unable to find.*Clojars" res)))
                            (user-error res)
                          (seq-filter
                           (lambda (x) (string-match-p ":lib" x))
                           (split-string res "\n")))))
              (seq-map
               (lambda (s)
                 (rx-let ((dep-rx (seq
                                   ":lib " (group-n 1 (one-or-more graph))
                                   (zero-or-one
                                    (seq blank ":version " (group-n 2 (one-or-more graph))))
                                   (zero-or-one
                                    (seq blank ":description " (group-n 3 (one-or-more ascii)))))))
                   (string-match (rx dep-rx) s)
                   (let ((lib (match-string 1 s))
                         (ver (match-string 2 s))
                         (desc (match-string 3 s)))
                     (list lib . ((when ver `(version . ,ver))
                                  (when desc `(description . ,desc)))))))
               res))))

         (exe (if-let ((exe (executable-find (or neil-executable-path "neil"))))
                  exe (user-error "Cannot find 'neil' cmd-line utility!")))

         (res (funcall perform-action exe (concat "dep search " (shell-quote-argument term))))
         (lib-name (let ((completion-extra-properties
                          '(:annotation-function neil-search-annotation-fn)))
                     (completing-read
                      (format "Found %s matches for '%s':" (length res) term)
                      res)))
         (version (if neil-prompt-for-version-p
                      (let ((versions (funcall perform-action exe (concat "dep versions " lib-name))))
                        (let (;; keeping the order in completion prompt is surprisingly tricky
                              (keep-order (lambda (completions)
                                            (lambda (string pred action)
                                              (if (eq action 'metadata)
                                                  `(metadata (display-sort-function . ,#'identity))
                                                (complete-with-action action completions string pred))))))
                          (completing-read
                           (format "Choose version of %s:" lib-name)
                           (funcall keep-order (seq-map (lambda (x) (alist-get 'version x)) versions)))))
                    (read (or (alist-get 'version (cdr (assoc lib-name res))) "nil"))))
         (dep-str (funcall format-dep-str lib-name version)))

    (when (and neil-inject-dep-to-project-p
               (eq 'clojure-cli (car (neil--identify-project-build-tool))))
      (funcall
       perform-action exe
       (format "dep add :lib %s :version %s" lib-name version)))

    (run-hook-with-args 'neil-after-find-clojure-package-hook dep-str)

    (kill-new dep-str)
    (message dep-str)))

(provide 'neil)

;;; neil.el ends here
