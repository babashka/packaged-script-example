;;; neil-tests.el --- tests for neil.el -*- lexical-binding: t; -*-
;;
;; Copyright (c) 2021 Michiel Borkent
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: May, 2022
;; Modified: May, 2022
;; Version: 0.0.1
;; Keywords: convenience tools
;; Homepage: https://github.com/babashka/neil
;; Package-Requires: ((emacs "28.1"))
;;
;;; Commentary:
;;
;;  Description
;;
;;; Code:

(require 'buttercup)
(require 'neil)

(describe "neil-find-clojure-package, no neil"
  (it "throws error when neil cmd-line executable not found"
    (spy-on #'executable-find :and-return-value nil)
    (expect (funcall #'neil-find-clojure-package "foo") :to-throw 'error)))

(describe "neil-find-clojure-package, happy path"
  :var (prompt-calls shell-cmd-calls)
  (before-each
    (setq prompt-calls 0
          shell-cmd-calls 0
          neil-inject-dep-to-project-p nil)
    (spy-on #'executable-find :and-return-value "/bin/neil")
    (spy-on #'shell-command-to-string
            :and-call-fake
            (lambda (command)
              ;; shell-command-to-string may get called multiple times, first to search
              ;; for packages, second time to get versions of a selected package,
              ;; arguments and the results differ every time
              (setf shell-cmd-calls (1+ shell-cmd-calls))
              (cond
               ((eq shell-cmd-calls 1)
                (expect command :to-equal "/bin/neil dep search test-pkg")
                (concat
                 ":lib foo/test-pkg :version \"1.0.0\" :description \"good lib\"\n"
                 ":lib bar/awesome-test-pkg :version \"2.1.0\" :description \"better lib\"\n"))

               ((eq shell-cmd-calls 2)
                 (expect command :to-equal "/bin/neil dep versions foo/test-pkg")
                 (concat
                  ":lib foo/test-pkg :version \"1.0.0\"\n"
                  ":lib bar/awesome-test-pkg :version \"2.1.0\"\n")))))
    (spy-on #'neil-search-annotation-fn)
    (spy-on #'completing-read
            :and-call-fake
            (lambda (prompt coll)
              ;; `neil-find-clojure-package' pops up completion prompt multiple times,
              ;; first to select from candidates matching the search term, second time, it
              ;; prompts for a version of the package - but only if
              ;; `neil-prompt-for-version-p' is not nil
              (setf prompt-calls (1+ prompt-calls))
              (cond
               ((eq prompt-calls 1)
                (expect prompt :to-equal "Found 2 matches for 'test-pkg':")
                (expect coll :to-equal
                        '(("foo/test-pkg"
                           (version . "\"1.0.0\"")
                           (description . "\"good lib\""))
                          ("bar/awesome-test-pkg"
                           (version . "\"2.1.0\"")
                           (description . "\"better lib\""))))
                "foo/test-pkg")

               ((eq prompt-calls 2)
                ;; TODO: figure out how to assert the sorted order of completion candidates
                (expect prompt :to-equal "Choose version of foo/test-pkg:")
                "1.0.0")))))

  (it "shouldn't throw 'executable not found' error"
    (expect (neil-find-clojure-package "test-pkg") :not :to-throw))

  (it "for clojure-cli, without version prompt"
    (spy-on #'neil--identify-project-build-tool :and-return-value '(clojure-cli))
    (let ((neil-prompt-for-version-p nil))
      (expect (neil-find-clojure-package "test-pkg") :to-equal
              "foo/test-pkg {:mvn/version \"1.0.0\"}")))

  (it "for clojure-cli, with version prompt"
    (spy-on #'neil--identify-project-build-tool :and-return-value '(clojure-cli))
    (let ((neil-prompt-for-version-p t))
      (expect (neil-find-clojure-package "test-pkg") :to-equal
              "foo/test-pkg {:mvn/version \"1.0.0\"}")))

  (it "for lein, without version prompt"
    (spy-on #'neil--identify-project-build-tool :and-return-value '(lein))
    (let ((neil-prompt-for-version-p nil))
      (expect (neil-find-clojure-package "test-pkg") :to-equal
              "[foo/test-pkg \"1.0.0\"]")))

  (it "for lein, with version prompt"
    (spy-on #'neil--identify-project-build-tool :and-return-value '(lein))
    (let ((neil-prompt-for-version-p t))
      (expect (neil-find-clojure-package "test-pkg") :to-equal
              "[foo/test-pkg \"1.0.0\"]")))

  (describe "testing hooks"
    (before-each
      (add-hook 'neil-after-find-clojure-package-hook 'test-hook-fn))
    (after-each
      (remove-hook 'neil-after-find-clojure-package-hook 'test-hook-fn))
    (it "after hook runs"
      (spy-on #'test-hook-fn :and-call-fake
              (lambda (coords)
                (expect (string= "foo/test-pkg {:mvn/version \"1.0.0\"}"
                                 coords))))
      (neil-find-clojure-package "test-pkg"))))

(describe "hot loading"
  (before-each
    (spy-on #'message))
  (it "cider not installed"
    (spy-on #'fboundp :and-call-through)
    (neil-cider-load-lib "foo")
    (expect #'message :to-have-been-called-with "CIDER not installed"))

  (it "cider not connected"
    (spy-on #'fboundp :and-call-fake (lambda (_) t))
    (spy-on #'cider-connected-p :and-return-value nil)
    (neil-cider-load-lib "foo")
    (expect #'message :to-have-been-called-with "CIDER not connected"))

  (it "not a deps.edn project"
    (spy-on #'fboundp :and-call-fake (lambda (_) t))
    (spy-on #'cider-connected-p :and-return-value t)
    (spy-on #'cider-project-type :and-return-value 'non-clojure-cli)
    (neil-cider-load-lib "foo")
    (expect #'message :to-have-been-called-with
            "Has to be deps.edn project for hot-loading"))

  (it "clojure version not supported"
    (spy-on #'fboundp :and-call-fake (lambda (_) t))
    (spy-on #'cider-connected-p :and-return-value t)
    (spy-on #'cider-project-type :and-return-value 'clojure-cli)
    (spy-on #'cider--clojure-version :and-return-value "1.11")
    (neil-cider-load-lib "foo")
    (expect #'message :to-have-been-called-with
            "You need at least 1.12.0-alpha2 of Clojure for hot-loading dependencies"))

  (it "attempts to load"
    (spy-on #'fboundp :and-call-fake (lambda (_) t))
    (spy-on #'cider-connected-p :and-return-value t)
    (spy-on #'cider-project-type :and-return-value 'clojure-cli)
    (spy-on #'cider--clojure-version :and-return-value "1.12.0-alpha3")
    (spy-on #'nrepl-dict-get :and-return-value nil)
    (spy-on #'cider-sync-tooling-eval :and-call-fake
            (lambda (input)
              (expect input :to-equal
                      "(add-libs '{cheshire/cheshire {:mvn/version \"5.13.0\"}})")))
    (neil-cider-load-lib "cheshire/cheshire {:mvn/version \"5.13.0\"}")))



;;; neil-tests.el ends here
