(ns babashka.neil
  {:no-doc true})

(require '[babashka.curl :as curl]
         '[babashka.fs :as fs]
         '[borkdude.rewrite-edn :as r]
         '[cheshire.core :as cheshire]
         '[clojure.edn :as edn]
         '[clojure.string :as str]
         '[clojure.pprint :refer [pprint]])

(def windows? (str/includes? (System/getProperty "os.name") "Windows"))

(def curl-opts
  {:throw false
   :compressed (not windows?)})

(defn latest-clojars-version [qlib]
  (-> (curl/get (format "https://clojars.org/api/artifacts/%s"
                        qlib)
                curl-opts)
      :body (cheshire/parse-string true)
      :latest_release))

(defn clojars-versions [qlib {:keys [limit] :or {limit "10"}}]
  ;; It looks like we call out to the Clojars' API to get /every/ version,
  ;; perhaps a performance problem. I couldn't find a way to specify a limit as
  ;; a query parameter.
  ;;
  ;; Clojars recent versions SQL:
  ;;
  ;;   https://github.com/clojars/clojars-web/blob/c6733177a4bae68f2537b34ddf09b17332c70ba7/resources/queries/queryfile.sql#L210-L219
  ;;
  ;; So instead, we just limit from our sequence.
  ;;
  ;; (TODO consider deleting this comment)
  (println (format "https://clojars.org/api/artifacts/%s" qlib))
  (let [limit (Long/parseLong limit)
        body
        (-> (curl/get (format "https://clojars.org/api/artifacts/%s"
                              qlib)
                      curl-opts)
            :body (cheshire/parse-string true))]
    (->> body
         :recent_versions
         (map :version)
         (take limit))))

(defn latest-mvn-version [qlib]
  (-> (curl/get (format "https://search.maven.org/solrsearch/select?q=g:%s+AND+a:%s&rows=1"
                        (namespace qlib)
                        (name qlib))
                curl-opts)
      :body (cheshire/parse-string true)
      :response
      :docs
      first
      :latestVersion))

(defn mvn-versions [qlib {:keys [limit] :or {limit "10"}}]
  (let [payload
        (-> (curl/get (format "https://search.maven.org/solrsearch/select?q=g:%s+AND+a:%s&core=gav&rows=%s"
                              (namespace qlib)
                              (name qlib)
                              limit)
                      curl-opts)
            :body
            (cheshire/parse-string true))]
    (->> payload
         :response :docs
         (map :v))))

(defn default-branch [lib]
  (-> (curl/get (format "https://api.github.com/repos/%s/%s"
                        (namespace lib) (name lib)))
      :body
      (cheshire/parse-string true)
      :default_branch))

(defn clean-github-lib [lib]
  (let [lib (str/replace lib "com.github." "")
        lib (str/replace lib "io.github." "")
        lib (symbol lib)]
    lib))

(defn latest-github-sha [lib]
  (let [lib (clean-github-lib lib)
        branch (default-branch lib)]
    (-> (curl/get (format "https://api.github.com/repos/%s/%s/commits/%s"
                          (namespace lib) (name lib) branch))
        :body
        (cheshire/parse-string true)
        :sha)))

(defn latest-github-tag [lib]
  (let [lib (clean-github-lib lib)]
    (-> (curl/get (format "https://api.github.com/repos/%s/%s/tags"
                          (namespace lib) (name lib)))
        :body
        (cheshire/parse-string true)
        first)))

(def deps-template
  (str/triml "
{:deps {}
 :aliases {}}
"))

(def bb-template
  (str/triml "
{:deps {}
 :tasks
 {
 }}
"))

(defn ensure-deps-file [opts]
  (let [target (:deps-file opts)]
    (when-not (fs/exists? target)
      (spit target (if (= "bb.edn" target)
                     bb-template
                     deps-template)))))

(defn edn-string [opts] (slurp (:deps-file opts)))

(defn edn-nodes [edn-string] (r/parse-string edn-string))

(defn parse-opts [opts]
  (let [[cmds opts] (split-with #(not (str/starts-with? % ":")) opts)]
    (into {:cmds cmds}
          (for [[arg-name arg-val] (partition 2 opts)]
            [(keyword (subs arg-name 1)) arg-val]))))

(def cognitect-test-runner-alias
  "
{:extra-paths [\"test\"]
 :extra-deps {io.github.cognitect-labs/test-runner
               {:git/tag \"v0.5.0\" :git/sha \"b3fd0d2\"}}
 :main-opts [\"-m\" \"cognitect.test-runner\"]
 :exec-fn cognitect.test-runner.api/test}")

(defn indent [s n]
  (let [spaces (apply str (repeat n " "))
        lines (str/split-lines s)]
    (str/join "\n" (map (fn [s]
                          (if (str/blank? s) s
                              (str spaces s))) lines))))

(defn clean-trailing-whitespace [s]
  (str/join "\n" (map str/trimr (str/split-lines s))))

(defn add-alias [opts alias-kw alias-contents]
  (ensure-deps-file opts)
  (let [edn-string (edn-string opts)
        edn-nodes (edn-nodes edn-string)
        edn (edn/read-string edn-string)
        alias (or (some-> (opts :alias) keyword)
                  alias-kw)
        alias-node (r/parse-string (str "\n " alias " ;; added by neil"))]
    (if-not (get-in edn [:aliases alias])
      (let [s (->> (r/update edn-nodes :aliases
                             (fn [aliases]
                               (let [s (indent alias-contents 1)
                                     alias-nodes (r/parse-string s)]
                                 (r/assoc aliases alias-node alias-nodes))))
                   str)
            s (clean-trailing-whitespace s)
            s (str s "\n")]
        (spit (:deps-file opts) s))
      (do (println (format "[neil] Project deps.edn already contains alias %s" (str alias ".")))
          ::update))))

(defn add-cognitect-test-runner [opts]
  (add-alias opts :test cognitect-test-runner-alias))

(def kaocha-alias
  "
{:extra-deps {lambdaisland/kaocha {:mvn/version \"1.0.887\"}}}")

(defn add-kaocha [opts]
  (add-alias opts :kaocha kaocha-alias))

(defn build-alias [opts]
  (let [latest-tag (latest-github-tag 'clojure/tools.build)
        tag (:name latest-tag)
        sha (-> latest-tag :commit :sha (subs 0 7))
        s (format "
{:deps {io.github.clojure/tools.build {:git/tag \"%s\" :git/sha \"%s\"}{{deps-deploy}}}
 :ns-default build}"
                  tag sha)]
    {:s (str/replace s "{{deps-deploy}}"
                     (if (:deps-deploy opts)
                       "\n        slipset/deps-deploy {:mvn/version \"0.2.0\"}"
                       ""))
     :tag tag
     :sha sha}))

(defn build-file
  [opts]
  (let [base "(ns build
  (:require [clojure.tools.build.api :as b]))

(def lib 'my/lib1)
(def version (format \"1.2.%s\" (b/git-count-revs nil)))
(def class-dir \"target/classes\")
(def basis (b/create-basis {:project \"deps.edn\"}))
(def uber-file (format \"target/%s-%s-standalone.jar\" (name lib) version))
(def jar-file (format \"target/%s-%s.jar\" (name lib) version))

(defn clean [_]
  (b/delete {:path \"target\"}))

(defn jar [_]
  (b/write-pom {:class-dir class-dir
                :lib lib
                :version version
                :basis basis
                :src-dirs [\"src\"]})
  (b/copy-dir {:src-dirs [\"src\" \"resources\"]
               :target-dir class-dir})
  (b/jar {:class-dir class-dir
          :jar-file jar-file}))

(defn uber [_]
  (clean nil)
  (b/copy-dir {:src-dirs [\"src\" \"resources\"]
               :target-dir class-dir})
  (b/compile-clj {:basis basis
                  :src-dirs [\"src\"]
                  :class-dir class-dir})
  (b/uber {:class-dir class-dir
           :uber-file uber-file
           :basis basis}))
"]
    (if (:deps-deploy opts)
      (str base
           "
(defn deploy [opts]
  (jar opts)
  ((requiring-resolve 'deps-deploy.deps-deploy/deploy)
    (merge {:installer :remote
                       :artifact jar-file
                       :pom-file (b/pom-path {:lib lib :class-dir class-dir})}
                    opts))
  opts)
")
      base)))

(defn add-build [opts]
  (if-not (fs/exists? "build.clj")
    (spit "build.clj" (build-file opts))
    (println "[neil] Project build.clj already exists."))
  (ensure-deps-file opts)
  (let [ba (build-alias opts)]
    (when (= ::update (add-alias opts :build (:s ba)))
      (println "[neil] Updating tools build to newest git tag + sha.")
      (let [edn-string (edn-string opts)
            edn (edn/read-string edn-string)
            build-alias (get-in edn [:aliases :build :deps 'io.github.clojure/tools.build])
            [tag-key sha-key]
            (cond (and
                   (:tag build-alias)
                   (:sha build-alias))
                  [:tag :sha]
                  (and
                   (:git/tag build-alias)
                   (:git/sha build-alias))
                  [:git/tag :git/sha])]
        (when (and tag-key sha-key)
          (let [nodes (edn-nodes edn-string)
                nodes (r/assoc-in nodes [:aliases :build :deps 'io.github.clojure/tools.build tag-key]
                                  (:tag ba))
                nodes (r/assoc-in nodes [:aliases :build :deps 'io.github.clojure/tools.build sha-key]
                                  (:sha ba))
                s (str (str/trim (str nodes)) "\n")]
            (spit (:deps-file opts) s)))))))

(defn add-dep [opts]
  (ensure-deps-file opts)
  (let [edn-string (edn-string opts)
        edn-nodes (edn-nodes edn-string)
        lib (or (:lib opts)
                (first (:cmds opts)))
        lib (symbol lib)
        git? (or (:sha opts)
                 (:latest-sha opts))
        mvn? (not git?)
        version (if git?
                  (or (:sha opts)
                      (latest-github-sha lib))
                  (or (:version opts)
                      (latest-clojars-version lib)
                      (latest-mvn-version lib)))
        git-url (when git?
                  (or (:git/url opts)
                      (str "https://github.com/" (clean-github-lib lib))))
        as (or (some-> (:as opts)
                       symbol) lib)
        ;; force newline
        edn-nodes (-> edn-nodes (r/assoc-in [:deps as] nil) str r/parse-string)
        nodes (cond
                mvn?
                (r/assoc-in edn-nodes [:deps as]
                            {:mvn/version version})
                git?
                ;; multiple steps to force newlines
                (-> edn-nodes
                    (r/assoc-in
                     [:deps as :git/url] git-url)
                    str
                    r/parse-string
                    (r/assoc-in
                     [:deps as :git/sha] version)))
        nodes (if-let [root (and git? (:deps/root opts))]
                (-> nodes
                    (r/assoc-in [:deps as :deps/root] root))
                nodes)
        s (str (str/trim (str nodes)) "\n")]
    (spit (:deps-file opts) s)))

(defn dep-versions [opts]
  (let [lib (or (:lib opts)
                (first (:cmds opts)))
        lib (symbol lib)
        git? (or (:sha opts)
                 (:latest-sha opts))
        versions (if git?
                   ::todo
                   (or (seq (clojars-versions lib opts))
                       (seq (mvn-versions lib opts))))]
    (doseq [v versions]
      (println :lib lib :version v))))

(defn print-help []
  (println (str/trim "
Usage: neil <subcommand> <options>

Most subcommands support the options:

- :alias - override alias name
- :deps-file - override deps.edn file name

Subcommands:

add

  - dep: adds :lib, a fully qualified symbol, to deps.edn :deps. Example:

    Options:

    :lib - Fully qualified symbol. :lib keyword may be elided when lib name is provided as first option.
    :version - Optional version. When not provided, picks newest version from Clojars or Maven Central.
    :sha - When provided, assumes lib refers to Github repo.
    :latest-sha - When provided, assumes lib refers to Github repo and then picks latest SHA from it.
    :deps/root - Set :deps/root to given value
    :as - Use as dependency name in deps.edn

  - test: adds cognitect test runner to :test alias.

  - build: adds tools.build build.clj file and :build alias.

    Options:

    :deps-deploy true - adds deps-deploy as dependency and deploy task in build.clj

  - kaocha: adds kaocha test runner to :koacha alias.
")))

(defn with-default-deps-edn [opts]
  (if (:deps-file opts)
    opts
    (assoc opts :deps-file "deps.edn")))

(defn add [[subcommand & opts]]
  (let [opts (parse-opts opts)
        opts (with-default-deps-edn opts)]
    (case subcommand
      "dep" (add-dep opts)
      "test" (add-cognitect-test-runner opts)
      "build" (add-build opts)
      "kaocha" (add-kaocha opts))))

(defn dep [[subcommand & opts]]
  (let [opts (parse-opts opts)
        opts (with-default-deps-edn opts)]
    (case subcommand
      "versions" (dep-versions opts)
      "add" (add-dep opts))))

(defn -main []
  (let [[subcommand & args] *command-line-args*]
    (case subcommand
      "add" (add args)
      "dep" (dep args)
      ("help" "--help") (print-help)
      (print-help))))

(when (= *file* (System/getProperty "babashka.file"))
  (-main))
