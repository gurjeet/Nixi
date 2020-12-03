;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2019, 2020 Timothy Sample <samplet@ngyro.com>
;;; Copyright © 2020 Jelle Licht <jlicht@fsfe.org>
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

(define-module (guix import npm-binary)
  #:use-module (guix import json)
  #:use-module (guix import utils)
  #:use-module (guix memoization)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 receive)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-41)
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:export (npm-binary-recursive-import
            npm-binary->guix-package))


(module-autoload! (current-module) '(semver)
                  '(string->semver
                    semver->string
                    semver?
                    semver=?
                    semver>?))

(module-autoload! (current-module) '(semver ranges)
                  '(string->semver-range
                    semver-range-contains?
                    *semver-range-any*))

(define-json-mapping <dist-tags> make-dist-tags dist-tags?
  json->dist-tags
  (latest dist-tags-latest "latest" string->semver))

(define-record-type <versioned-package>
  (make-versioned-package name version)
  versioned-package?
  (name  versioned-package-name)       ;string
  (version versioned-package-version)) ;string

(define (dependencies->versioned-packages entries)
  (match entries
    (((names . versions) ...)
     (map make-versioned-package names versions))
    (_ '())))

(define-json-mapping <dist> make-dist dist?
  json->dist
  (tarball dist-tarball))

(define-json-mapping <package-revision> make-package-revision package-revision?
  json->package-revision
  (name package-revision-name)
  (version package-revision-version "version" string->semver) ;semver
  (home-page package-revision-home-page "homepage")           ;string
  (dependencies package-revision-dependencies "dependencies" ;list of versioned-package
                dependencies->versioned-packages)
  (license package-revision-license "license" spdx-string->license) ;license
  (description package-revision-description)                        ;string
  (dist package-revision-dist "dist" json->dist))                   ;dist

(define (versions->package-revisions versions)
  (match versions
    (((version . package-spec) ...)
     (map json->package-revision package-spec))
    (_ '())))

(define (versions->package-versions versions)
  (match versions
    (((version . package-spec) ...)
     (map string->semver versions))
    (_ '())))

(define-json-mapping <meta-package> make-meta-package meta-package?
  json->meta-package
  (name meta-package-name)                                       ;string
  (description meta-package-description)                         ;string
  (dist-tags meta-package-dist-tags "dist-tags" json->dist-tags) ;dist-tags
  (revisions meta-package-revisions "versions" versions->package-revisions))

(define *registry* (string->uri "https://registry.npmjs.org"))

(define lookup-meta-package
  (mlambda (name)
    (let ((uri (build-uri (uri-scheme *registry*)
                          #:host (uri-host *registry*)
                          #:path (string-append "/" (uri-encode name)))))
      (receive (response body)
          (http-get uri #:streaming? #t)
        (let ((status (response-code response)))
          (unless (and (<= 200 status) (< status 300))
            (scm-error 'http-error "lookup-meta-package"
                       "Received HTTP error: ~s: ~s for ~s"
                       (list (response-code response)
                             (response-reason-phrase response))
                       (list (response-code response)))))
        (json->meta-package body)))))

(define (http-error-code arglist)
  (match arglist
    (('http-error _ _ _ (code)) code)
    (_ #f)))

(define (meta-package-versions meta)
  (map package-revision-version
       (meta-package-revisions meta)))

(define (meta-package-latest meta)
  (and=> (meta-package-dist-tags meta) dist-tags-latest))

(define* (meta-package-package meta #:optional
                               (version (meta-package-latest meta)))
  (match version
    ((? semver?) (find (lambda (revision)
                         (semver=? version (package-revision-version revision)))
                       (meta-package-revisions meta)))
    ((? string?) (meta-package-package meta (string->semver version)))
    (_ #f)))

(define* (semver-latest svs #:optional (svr *semver-range-any*))
  (find (cut semver-range-contains? svr <>)
        (sort svs semver>?)))

(define* (resolve-package name #:optional (svr *semver-range-any*))
  (let* ((meta (lookup-meta-package name))
         (version (semver-latest (or (meta-package-versions meta) '()) svr))
         (pkg (meta-package-package meta version)))
    pkg))


;;;
;;; Converting packages
;;;

(define (hash-url url)
  "Downloads the resource at URL and computes the base32 hash for it."
  (call-with-temporary-output-file
   (lambda (temp port)
     (begin ((@ (guix import utils) url-fetch) url temp)
            (guix-hash-url temp)))))

(define *suffix* "--binary")

(define (npm-name->name npm-name)
  "Return a Guix package name for the npm package with name NPM-NAME."
  (define (clean name)
    (string-map (lambda (chr) (if (char=? chr #\/) #\- chr))
                (string-filter (negate (cut char=? <> #\@)) name)))
  (string-append (guix-name "node-" (clean npm-name)) *suffix*))

(define (npm-name->input npm-name)
  "Return the `inputs' entry for NPM-NAME."
  (let ((name (npm-name->name npm-name)))
    `(,(if (string-suffix? *suffix* name)
           (string-drop-right name (string-length *suffix*))
           name)
      (,'unquote ,(string->symbol name)))))

(define (npm-package->package-sexp npm-package)
  "Return the `package' s-expression for an NPM-PACKAGE."
  (match npm-package
    (($ <package-revision> name version home-page dependencies license description dist)
     (let* ((name (npm-name->name name))
            (url (dist-tarball dist))
            (dependency-names (map versioned-package-name dependencies))
            (synopsis description))
       (values
        `(package
           (name ,name)
           (version ,(semver->string (package-revision-version npm-package)))
           (source (origin
                     (method url-fetch)
                     (uri ,url)
                     (sha256 (base32 ,(hash-url url)))))
           (build-system node-build-system)
           (arguments
            `(#:phases
              (modify-phases %standard-phases
                (delete 'configure)
                (delete 'build))))
           ,@(match dependency-names
               (() '())
               ((dependency-names ...)
                `((inputs
                   (,'quasiquote ,(map npm-name->input
                                       (sort dependency-names string<)))))))
           (home-page ,home-page)
           (synopsis ,synopsis)
           (description ,description)
           (license ,license))
        (map (match-lambda (($ <versioned-package> name version)
                            (list name version)))
             dependencies))))
    (_ #f)))


;;;
;;; Interface
;;;

(define npm-binary->guix-package
  ;; (memoize)
  (lambda* (name #:key (version *semver-range-any*) #:allow-other-keys)
    (let* ((svr (match version
                  ((? string?) (string->semver-range version))
                  (_ version)))
           (pkg (resolve-package name svr)))
      (npm-package->package-sexp pkg))))

(define* (npm-binary-recursive-import package-name #:key version)
  (recursive-import package-name
                    #:repo->guix-package npm-binary->guix-package
                    #:version version
                    #:guix-name npm-name->name))
