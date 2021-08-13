#lang racket
(provide
 adir-temp
 dry-run
 has-dispatch?
 process-tbi)
(require chk)
(require aws/keys)
(require aws/s3)
(require "../db/dispatch-build-kg-indexes.rkt")
(require "../../stuff/run-shell-pipelines.rkt")
(require "metadata.rkt")
(require "current-source.rkt")
(require "cmd-helpers.rkt")
(require "dispatch-params.rkt")

;task-build-index
;task-build-index-kgec

(define delimiter-s3 "/")


(define (update-vals-by-key keys vals k v)
  (let ((i (index-of k keys)))
    (if i
        (list-set vals i v)
        (error (printf "update-vals-by-key: key ~s not found in ~s" k keys)))))

(define dr-make-directory (dry-runify make-directory 'make-directory))

(define (ensure-file-or-directory-link adir1 adir2)
  (when (link-exists? adir2)
    (delete-file adir2))
  (make-file-or-directory-link adir1 adir2))

(define dr-ensure-file-or-directory-link (dry-runify ensure-file-or-directory-link 'ensure-file-or-directory-link))

(define dr-delete-file (dry-runify delete-file 'delete-file))


(define (sha1sum afile)
  (if (dry-run)
      "1234567890123456789012345678901234567890"
      (run-pipelines 
       `(((#:out) ()
                  ("sha1sum" ,afile)
                  ("cut" "-c1-40")
                  )))))

(define (rfile-output tbi)
  (define kgec (task-build-index-kgec tbi))
  (define kgid (kge-coord-kgid kgec))
  (define ver (kge-coord-ver kgec))
  (define mi (task-build-index-ver-mi tbi))
  (format "~a-~a_mi~a" kgid ver mi))


(define (expand-payload tbi)
  (define kgec (task-build-index-kgec tbi))
  (define kgid (kge-coord-kgid kgec))
  (define ver (kge-coord-ver kgec))
  (define afile-archive (path->string (build-path (adir-temp) (payload-from-kgec kgec))))
  (define sha1 (sha1sum afile-archive))    ; TODO: check sha1 against upstream
  ;; Q: Does the place for extracting the data need to be unique?
  ;; A: No, in fact it being unique would mean that a db/foo.rkt would have to change the
  ;; 'source-file-path in each of its define-relation/table statements, which would be burdensome.
  (define adir-data1 (path->string (build-path (adir-temp) "data")))
  (dr-make-directory adir-data1)
  (dr-make-directory (path->string (build-path (adir-temp) "data" "upstream")))
  (define adir-payload (path->string (build-path (adir-temp) "data" "upstream" kgid))) ; ver purposely omitted
  (dr-make-directory adir-payload)
  (define adir-data2 (path->string (build-path (adir-repo-ingest) "medikanren2" "data")))
  (define cmds-expand
    `((() () ("ls" "-lR" ,(adir-temp)))
      (() ()
          ("tar" "xzf" ,afile-archive "-C" ,adir-payload))
      (() () ("ls" "-lR" ,(adir-temp)))
      ))
  ; TODO capture ls -lR of what was in the archive
  ;(define cmds^ (run-pipeline-stdin-from-request request-inport cmds))
  ; TODO: check symlink:  medikanren2/data and symlink adir-payload to it
  (dr-ensure-file-or-directory-link adir-data1 adir-data2)
  ; TODO: fix:
  ;   make-file-or-directory-link: cannot make link;
  ;    the path already exists
  ;     path: /var/tmp/medikanren_16287039581628703958190/data
  (run-cmds cmds-expand)
  (dr-delete-file afile-archive))

(define (cmd-require-racket adir rfile-rkt)
  `((() () ("bash" "-c" ,(format "cd '~a'; pwd; racket -e '(require \"medikanren2/db/~a\")'" adir rfile-rkt)))))

(module+ test
  (chk
   #:do (run-pipelines (cmd-require-racket "stuff" "run-shell-pipelines.rkt"))
   #t)
  )

(define (has-dispatch? idver)
  (match idver
    (`(idver ,kgid ,ver)
     (list? (dispatch-build-kg kgid ver)))))

(define ((kg-ref key (val-default 'kg-ref-default)) kgid ver)
  (define kg (dispatch-build-kg kgid ver))
  (if (dict-has-key? kg key)
      (dict-ref kg key)
      (begin
        (unless (not (equal? val-default 'kg-ref-default))
          (error (format "dispatch-build-kg-indexes key ~a is required for kgid=~a version=~a" key kgid ver)))
        val-default)))

(define require-file-from-kg (kg-ref 'require-file))
(define shell-pipeline-before (kg-ref 'shell-pipeline-before '()))
(define local-name-from-kg (kg-ref 'local-name))

(define (dispatch-build-impl tbi)
  (define kgid (kge-coord-kgid (task-build-index-kgec tbi)))
  (define adir-payload (path->string (build-path (adir-temp) "data" "upstream" kgid))) ; ver purposely omitted
  (define kgec (task-build-index-kgec tbi))
  (define adir-base (build-path (adir-repo-ingest) "medikanren2"))
  ; TODO: copy file_set.yaml, provider.yaml
  (let ((rfile-to-require (require-file-from-kg (kge-coord-kgid kgec) (kge-coord-ver kgec)))
        (cmds-before (shell-pipeline-before (kge-coord-kgid kgec) (kge-coord-ver kgec))))
    (begin
      (report-invalid-pipelines cmds-before)
      (let ((cmds-require (cmd-require-racket (adir-repo-ingest) rfile-to-require)))
        (run-cmds (append cmds-before cmds-require))))))

(define (compress-out tbi)
  (define kgec (task-build-index-kgec tbi))
  (let ((local-name (local-name-from-kg (kge-coord-kgid kgec) (kge-coord-ver kgec))))
    (begin
      (define kgid (kge-coord-kgid (task-build-index-kgec tbi)))
      (define ver (kge-coord-ver (task-build-index-kgec tbi)))
      (define adir-data1 (path->string (build-path (adir-temp) "data")))
      (define rfile (rfile-output tbi))
      (define afile-archout (path->string (build-path (adir-temp) (format "~a.tgz" rfile))))
      (define adir-split (path->string (build-path (adir-temp) "split")))
      (dr-make-directory adir-split)
      (define afile-split (path->string (build-path (adir-temp) "split" (format "~a.tgz.split." rfile))))
      (define adir-data (path->string (build-path (adir-repo-ingest) "medikanren2" "data")))
      (run-cmds
       `(  (() () ("tar" "czf" ,afile-archout "-C" ,adir-data1 ,local-name))
           (() () ("split" "--bytes=1G" ,afile-archout ,afile-split))
           (() () ("ls" "-l" ,adir-split))
           ))
      ; TODO: now that tgz is generated, sha1sum it and generate yaml
      )))

(define (make-s3dir s3path-base tbi)
  (define kgec (task-build-index-kgec tbi))
  (define kgid (kge-coord-kgid kgec))
  (define ver (kge-coord-ver kgec))
  (define ver-mi (task-build-index-ver-mi tbi))
  (format "~a/kgid/~a/v/~a/mi/~a" s3path-base kgid ver ver-mi)) ; TODO: omit "/" from "/kgid" or from s3path-base?

(define (upload-archive-out s3dir)
  (define adir-split (build-path (adir-temp) "split"))
  (define patels (directory-list adir-split #:build? #f))
  ; TODO extract method for better dryrun copy-dir-to-s3
  (for ((patel patels))
    (let ((s3path (format "~a/~a" s3dir patel)))
      (multipart-put/file s3path (build-path adir-split patel))
      ; TODO copy yaml
      )))

(define dr-upload-archive-out (dry-runify upload-archive-out 'upload-archive-out))

(define (check-for-payload tbi)
  (define afile (path->string (build-path (adir-temp) (payload-from-kgec (task-build-index-kgec tbi)))))
  (if (dry-run)
      (displayln `(check-for-payload ,afile))
      (unless (file-exists? afile)
        (error (format "Caller must supply a file at: ~a" afile)))))

(define (process-tbi s3path-base tbi)
  (check-for-payload tbi)  ; TODO
  (expand-payload tbi)
  (dispatch-build-impl tbi)
  (compress-out tbi)
  (dr-upload-archive-out (make-s3dir s3path-base tbi)))
; TODO: promote temp dir context to main
; TODO: leave for find-kgv-tosync: sha1, size
;       recompute from tbi: reldir, filename



