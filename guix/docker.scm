;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2017 Ricardo Wurmus <rekado@elephly.net>
;;; Copyright © 2017, 2018, 2019, 2021 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2018 Chris Marusich <cmmarusich@gmail.com>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix docker)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module ((guix build utils)
                #:select (mkdir-p
                          delete-file-recursively
                          with-directory-excursion
                          invoke))
  #:use-module (gnu build install)
  #:use-module (json)                             ;guile-json
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (srfi srfi-26)
  #:use-module ((texinfo string-utils)
                #:select (escape-special-chars))
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:export (build-docker-image))

;; Generate a 256-bit identifier in hexadecimal encoding for the Docker image.
(define docker-id
  (compose bytevector->base16-string sha256 string->utf8))

(define (layer-diff-id layer)
  "Generate a layer DiffID for the given LAYER archive."
  (string-append "sha256:" (bytevector->base16-string (file-sha256 layer))))

;; This is the semantic version of the JSON metadata schema according to
;; https://github.com/docker/docker/blob/master/image/spec/v1.2.md
;; It is NOT the version of the image specification.
(define schema-version "1.0")

(define (image-description id time)
  "Generate a simple image description."
  `((id . ,id)
    (created . ,time)
    (container_config . #nil)))

(define (canonicalize-repository-name name)
  "\"Repository\" names are restricted to roughtl [a-z0-9_.-].
Return a version of TAG that follows these rules."
  (define ascii-letters
    (string->char-set "abcdefghijklmnopqrstuvwxyz"))

  (define separators
    (string->char-set "_-."))

  (define repo-char-set
    (char-set-union char-set:digit ascii-letters separators))

  (string-map (lambda (chr)
                (if (char-set-contains? repo-char-set chr)
                    chr
                    #\.))
              (string-trim (string-downcase name) separators)))

(define* (manifest path id #:optional (tag "guix"))
  "Generate a simple image manifest."
  (let ((tag (canonicalize-repository-name tag)))
    `#(((Config . "config.json")
        (RepoTags . #(,(string-append tag ":latest")))
        (Layers . #(,(string-append id "/layer.tar")))))))

;; According to the specifications this is required for backwards
;; compatibility.  It duplicates information provided by the manifest.
(define* (repositories path id #:optional (tag "guix"))
  "Generate a repositories file referencing PATH and the image ID."
  `((,(canonicalize-repository-name tag) . ((latest . ,id)))))

;; See https://github.com/opencontainers/image-spec/blob/master/config.md
(define* (config layer time arch #:key entry-point (environment '()))
  "Generate a minimal image configuration for the given LAYER file."
  ;; "architecture" must be values matching "platform.arch" in the
  ;; runtime-spec at
  ;; https://github.com/opencontainers/runtime-spec/blob/v1.0.0-rc2/config.md#platform
  `((architecture . ,arch)
    (comment . "Generated by GNU Guix")
    (created . ,time)
    (config . ,`((env . ,(list->vector
                          (map (match-lambda
                                 ((name . value)
                                  (string-append name "=" value)))
                               environment)))
                 ,@(if entry-point
                       `((entrypoint . ,(list->vector entry-point)))
                       '())))
    (container_config . #nil)
    (os . "linux")
    (rootfs . ((type . "layers")
               (diff_ids . #(,(layer-diff-id layer)))))))

(define %tar-determinism-options
  ;; GNU tar options to produce archives deterministically.
  '("--sort=name" "--mtime=@1"
    "--owner=root:0" "--group=root:0"

    ;; When 'build-docker-image' is passed store items, the 'nlink' of the
    ;; files therein leads tar to store hard links instead of actual copies.
    ;; However, the 'nlink' count depends on deduplication in the store; it's
    ;; an "implicit input" to the build process.  '--hard-dereference'
    ;; eliminates it.
    "--hard-dereference"))

(define directive-file
  ;; Return the file or directory created by a 'evaluate-populate-directive'
  ;; directive.
  (match-lambda
    ((source '-> target)
     (string-trim source #\/))
    (('directory name _ ...)
     (string-trim name #\/))))

(define* (build-docker-image image paths prefix
                             #:key
                             (repository "guix")
                             (extra-files '())
                             (transformations '())
                             (system (utsname:machine (uname)))
                             database
                             entry-point
                             (environment '())
                             compressor
                             (creation-time (current-time time-utc)))
  "Write to IMAGE a Docker image archive containing the given PATHS.  PREFIX
must be a store path that is a prefix of any store paths in PATHS.  REPOSITORY
is a descriptive name that will show up in \"REPOSITORY\" column of the output
of \"docker images\".

When DATABASE is true, copy it to /var/guix/db in the image and create
/var/guix/gcroots and friends.

When ENTRY-POINT is true, it must be a list of strings; it is stored as the
entry point in the Docker image JSON structure.

ENVIRONMENT must be a list of name/value pairs.  It specifies the environment
variables that must be defined in the resulting image.

EXTRA-FILES must be a list of directives for 'evaluate-populate-directive'
describing non-store files that must be created in the image.

TRANSFORMATIONS must be a list of (OLD -> NEW) tuples describing how to
transform the PATHS.  Any path in PATHS that begins with OLD will be rewritten
in the Docker image so that it begins with NEW instead.  If a path is a
non-empty directory, then its contents will be recursively added, as well.

SYSTEM is a GNU triplet (or prefix thereof) of the system the binaries in
PATHS are for; it is used to produce metadata in the image.  Use COMPRESSOR, a
command such as '(\"gzip\" \"-9n\"), to compress IMAGE.  Use CREATION-TIME, a
SRFI-19 time-utc object, as the creation time in metadata."
  (define (sanitize path-fragment)
    (escape-special-chars
     ;; GNU tar strips the leading slash off of absolute paths before applying
     ;; the transformations, so we need to do the same, or else our
     ;; replacements won't match any paths.
     (string-trim path-fragment #\/)
     ;; Escape the basic regexp special characters (see: "(sed) BRE syntax").
     ;; We also need to escape "/" because we use it as a delimiter.
     "/*.^$[]\\"
     #\\))
  (define transformation->replacement
    (match-lambda
      ((old '-> new)
       ;; See "(tar) transform" for details on the expression syntax.
       (string-append "s/^" (sanitize old) "/" (sanitize new) "/"))))
  (define (transformations->expression transformations)
    (let ((replacements (map transformation->replacement transformations)))
      (string-append
       ;; Avoid transforming link targets, since that would break some links
       ;; (e.g., symlinks that point to an absolute store path).
       "flags=rSH;"
       (string-join replacements ";")
       ;; Some paths might still have a leading path delimiter even after tar
       ;; transforms them (e.g., "/a/b" might be transformed into "/b"), so
       ;; strip any leading path delimiters that remain.
       ";s,^//*,,")))
  (define transformation-options
    (if (eq? '() transformations)
        '()
        `("--transform" ,(transformations->expression transformations))))
  (let* ((directory "/tmp/docker-image") ;temporary working directory
         (id (docker-id prefix))
         (time (date->string (time-utc->date creation-time) "~4"))
         (arch (let-syntax ((cond* (syntax-rules ()
                                     ((_ (pattern clause) ...)
                                      (cond ((string-prefix? pattern system)
                                             clause)
                                            ...
                                            (else
                                             (error "unsupported system"
                                                    system)))))))
                 (cond* ("x86_64" "amd64")
                        ("i686"   "386")
                        ("arm"    "arm")
                        ("mips64" "mips64le")))))
    ;; Make sure we start with a fresh, empty working directory.
    (mkdir directory)
    (with-directory-excursion directory
      (mkdir id)
      (with-directory-excursion id
        (with-output-to-file "VERSION"
          (lambda () (display schema-version)))
        (with-output-to-file "json"
          (lambda () (scm->json (image-description id time))))

        ;; Create a directory for the non-store files that need to go into the
        ;; archive.
        (mkdir "extra")

        (with-directory-excursion "extra"
          ;; Create non-store files.
          (for-each (cut evaluate-populate-directive <> "./")
                    extra-files)

          (when database
            ;; Initialize /var/guix, assuming PREFIX points to a profile.
            (install-database-and-gc-roots "." database prefix))

          (apply invoke "tar" "-cf" "../layer.tar"
                 `(,@transformation-options
                   ,@%tar-determinism-options
                   ,@paths
                   ,@(scandir "."
                              (lambda (file)
                                (not (member file '("." ".."))))))))

        ;; It is possible for "/" to show up in the archive, especially when
        ;; applying transformations.  For example, the transformation
        ;; "s,^/a,," will (perhaps surprisingly) cause GNU tar to transform
        ;; the path "/a" into "/".  The presence of "/" in the archive is
        ;; probably benign, but it is definitely safe to remove it, so let's
        ;; do that.  This fails when "/" is not in the archive, so use system*
        ;; instead of invoke to avoid an exception in that case, and redirect
        ;; stderr to the bit bucket to avoid "Exiting with failure status"
        ;; error messages.
        (with-error-to-port (%make-void-port "w")
          (lambda ()
            (system* "tar" "--delete" "/" "-f" "layer.tar")))

        (delete-file-recursively "extra"))

      (with-output-to-file "config.json"
        (lambda ()
          (scm->json (config (string-append id "/layer.tar")
                             time arch
                             #:environment environment
                             #:entry-point entry-point))))
      (with-output-to-file "manifest.json"
        (lambda ()
          (scm->json (manifest prefix id repository))))
      (with-output-to-file "repositories"
        (lambda ()
          (scm->json (repositories prefix id repository)))))

    (apply invoke "tar" "-cf" image "-C" directory
           `(,@%tar-determinism-options
             ,@(if compressor
                   (list "-I" (string-join compressor))
                   '())
             "."))
    (delete-file-recursively directory)))
