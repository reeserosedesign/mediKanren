#lang racket/base
(provide trapi-response)
(require
 "common.rkt" 
 "lw-reasoning.rkt"
 "logging.rkt"
  racket/file racket/function racket/list racket/hash
  (except-in racket/match ==)
  racket/port
  racket/pretty
  racket/runtime-path
  racket/string
  json
  memoize
  racket/format
  racket/dict
  racket/set
  )
 

;; QUESTION
;; - Do we return all attributes, or only specified ones?
;; - How is knowledge_graph used in queries?

;; TODO (trapi.rkt and server.rkt)
;; - status - logs - description
;; - Understand Attribute types
;; - QEdge constraints
;; - QNode is_set:
;;       Boolean that if set to true, indicates that this QNode MAY
;;       have multiple KnowledgeGraph Nodes bound to it wi;; thin each
;;       Result. The nodes in a set should be considered as a set of
;;       independent nodes, rather than a set of dependent nodes,
;;       i.e., the answer would still be valid if the nodes in the set
;;       were instead returned individually. Multiple QNodes may have
;;       is_set=True. If a QNode (n1) with is_set=True is connected to
;;       a QNode (n2) with is_set=False, each n1 must be connected to
;;       n2. If a QNode (n1) with is_set=True is connected to a QNode
;;       (n2) with is_set=True, each n1 must be connected to at least
;;       one n2.

(define use-reasoning? (make-parameter #f))

(define trapi-response-node-properties '("category" "name"))
(define trapi-response-node-attributes '(("umls_type_label" . "miscellaneous")
                                         ("umls_type" . "miscellaneous")
                                         ("xrefs" . "miscellaneous")))
(define trapi-response-edge-properties '("predicate" "relation" "subject" "object"))
(define trapi-response-edge-attributes '(("negated" . "miscellaneous")
                                         ("provided_by" . "miscellaneous")
                                         ("publications" . "miscellaneous")))

(define (alist-ref alist key default)
  ;; WEB  FIXME unchecked 'assoc' result
  (define kv (assoc key alist))
  (if kv (cdr kv) default))

(define hash-empty (hash))
(define (str   v) (if (string? v) v (error (format "invalid string: ~s" v))))
(define (olift v) (if (hash?   v) v (error (format "invalid object: ~s" v))))
(define (slift v) (cond ((pair?   v) v)
                        ((string? v) (list v))
                        ((null?   v) '())
                        (else        (error (format "invalid string or list of strings: ~s" v)))))
(define (alist-of-hashes->lists v)
  (map (lambda (pair)
         (cons (car pair) (hash->list (olift (cdr pair)))))
       v))
(define (symlift v) 
  (cond ((number? v) (string->symbol (number->string v)))
        ((string? v) (string->symbol v))
        ((symbol? v) v)
        (else (error (format "Must be a number, string or symbol: ~s." v)))))

(define (strlift v)
  (cond ((number? v) (number->string v))
        ((string? v) v)
        ((symbol? v) (symbol->string v))
        (error (format "Must be a number, string or symbol: ~s" v))))

(define (trapi-response msg)
  (define log-key "[query]")
  (define max-results (hash-ref msg 'max_results #f))
  (define qgraph (hash-ref msg 'query_graph #f))
  (define kgraph (hash-ref msg 'knowledge_graph #f))
  (define request-valid? (not (not qgraph)))

  (if (not request-valid?)
    (hash 'results '()
          'knowledge_graph
          (hash 'nodes '#hash()
                'edges '#hash()))
    (let ((results (if max-results
                          (run max-results bindings (trapi-query qgraph kgraph bindings log-key))
                          (run* bindings (trapi-query qgraph kgraph bindings log-key)))))
      (hash 'results (trapi-response-results results qgraph)
            'knowledge_graph
            (hash 'nodes (trapi-response-knodes results)
                  'edges (trapi-response-kedges results))))))

(define (trapi-query qgraph kgraph bindings log-key)
  (define nodes  (hash->list (olift (hash-ref qgraph 'nodes hash-empty))))
  (define edges  (hash->list (olift (hash-ref qgraph 'edges hash-empty))))

  ;; Interpret included KnowledgeGraph element
  (define knodes (and kgraph
                      (alist-of-hashes->lists
                       (hash->list (olift (hash-ref kgraph 'nodes hash-empty))))))
  (define kedges (and kgraph (alist-of-hashes->lists
                              (hash->list (olift (hash-ref kgraph 'edges hash-empty))))))
  (define-relation (k-is-a concept category)
    (fresh (props concept-sym category-sym)
      (membero `(,concept-sym . ,props) knodes)
      (membero `(category . ,category) props)
      (:== concept-sym (concept) (string->symbol concept))
      (:== category-sym (category) (string->symbol category))))
  (define-relation (k-triple eid s p o)
    (fresh (props)
      (membero `(,eid . ,props) kedges)
      (membero `(subject . ,s) props)
      (membero `(predicate . ,p) props)
      (membero `(object . ,o) props)))

    (let ((full-reasoning? (hash-ref qgraph 'use_reasoning #t)))
      (fresh (node-bindings edge-bindings)
        (== bindings `((node_bindings . ,node-bindings) 
                       (edge_bindings . ,edge-bindings)))
        ((trapi-nodes nodes k-is-a full-reasoning? log-key) node-bindings)
        ((trapi-edges edges k-triple full-reasoning? log-key) node-bindings edge-bindings))))

(define (trapi-nodes nodes k-is-a full-reasoning? log-key)
  (relation trapi-nodes-o (bindings)
    (begin
      (printf "entering trapi-nodes loop...\n")
      (let loop ((nodes nodes)
                 (bindings bindings))
        (if (null? nodes)
            (== bindings '())
            (let* ((id+n        (car nodes))
                   (id          (car id+n))
                   (n           (cdr id+n))
                   (curie       (hash-ref n 'id #f)) ; deprecated v1.1
                   (curies      (hash-ref n 'ids (and curie 
                                                      (if (pair? curie) curie
                                                          (list curie)))))
                   (category   (hash-ref n 'category #f)) ; deprecated v1.1
                   (categories  (hash-ref n 'categories (and category 
                                                             (if (pair? category) category
                                                                 (list category)))))
                   (constraints (hash-ref n 'constraints '()))
                   (is-set?     (hash-ref n 'is_set #f))
                   (reasoning?  (hash-ref n 'use_reasoning #f)))
              (printf "--------------\n")
              (printf "id: ~s\n" id)
              (printf "n: ~s\n" n)
              (printf "curie (deprecated): ~s\n" curie)
              (printf "curies: ~s\n" curies)
              (printf "category (deprecated): ~s\n" category)
              (printf "categories: ~s\n" categories)
              (printf "constraints: ~s\n" constraints)
              (printf "is-set?: ~s\n" is-set?)
              (printf "reasoning?: ~s\n" reasoning?)
              (printf "--------------\n")
              (if curies
                  (if (pair? curies)
                      ;; WEB TODO FIXME Shouldn't we be
                      ;; simulataneously checking for subclasses of
                      ;; categories (as in the code below, for when no
                      ;; curies are specified), if categories are
                      ;; present for the node, and reasoning? or
                      ;; full-reasoning? is true?
                      (let ((curies
                             (if (or reasoning? full-reasoning?)
                                 (log-time log-once log-key 
                                           (format "Subclasses/synonyms of ~s" curies)
                                           (get-synonyms-ls (subclasses/set curies)))
                                 curies)))
                        (fresh (curie k+v bindings-rest)
                          (== bindings `(,k+v . ,bindings-rest))
                          (== k+v `(,id . ,curie))
                          (membero curie curies)
                          ((trapi-constraints constraints) curie)
                          (loop (cdr nodes) bindings-rest)))
                      (error (format
                              "Field: 'QNode/ids' must be array of CURIEs (TRAPI 1.1), but given ~s\n"
                              curies)))
                  (if categories
                      (if (pair? categories)
                          (let ((categories (if (or reasoning? full-reasoning?)
                                                (log-time log-once log-key 
                                                          (format "Subclasses of ~s" categories)
                                                          (subclasses/set categories))
                                                categories)))
                            (fresh (cat curie k+v bindings-rest)
                              (== k+v `(,id . ,curie))
                              (== bindings `(,k+v . ,bindings-rest))
                              ((trapi-constraints constraints) curie)
                              (membero cat categories)
                              (conde ((is-a curie cat))
                                     ((k-is-a curie cat)))
                              (loop (cdr nodes) bindings-rest)))
                          (error (format
                                  "Field: 'QNode/categories' must be array of CURIEs (TRAPI 1.1), but given ~s\n"
                                  categories)))
                      ;; No ids (CURIEs) or categories specified for the node:
                      (fresh (curie k+v bindings-rest)
                          (== bindings `(,k+v . ,bindings-rest))
                          (== k+v `(,id . ,curie))
                          ((trapi-constraints constraints) curie)
                          (loop (cdr nodes) bindings-rest))))))))))

(define (trapi-edges edges k-triple full-reasoning? log-key)
  (relation trapi-edges-o (node-bindings edge-bindings)
    (let loop ((edges edges) (bindings edge-bindings))
      (if (null? edges)
          (== bindings '()) 
          (let* ((id+e        (car edges))
                 (id          (car id+e))
                 (e           (cdr id+e))
                 (predicate   (hash-ref e 'predicate #f)) ; deprecated v1.1
                 (predicates  (hash-ref e 'predicates (and predicate
                                                           (if (pair? predicate) predicate
                                                               (list predicate)))))
                 (subject-symbol (hash-ref e 'subject #f))
                 (subject     (if subject-symbol
                                  (string->symbol subject-symbol)
                                  (error (format "subject not found in e:\n~s" e))))
                 (relation    (hash-ref e 'relation #f))
                 (object-symbol (hash-ref e 'object #f))
                 (object      (if object-symbol
                                  (string->symbol object-symbol)
                                  (error (format "object not found in e:\n~s" e))))
                 (constraints (hash-ref e 'constraints '()))
                 (reasoning?  (hash-ref e 'use_reasoning #f)))
            (if (and predicates (not (pair? predicates)))
                (error (format
                         "Field: 'QEdge/predicates' must be an array of CURIEs (TRAPI 1.1).  Given ~s\n"
                         predicates))
                (let ((predicates (if (and (or reasoning? full-reasoning?) predicates)
                                      (log-time log-once log-key 
                                                (format "Subclasses of ~s" predicates)
                                                (subclasses/set predicates))
                                      predicates)))
                  (fresh (db+id s p o bindings-rest)
                    (membero `(,subject . ,s) node-bindings)
                    (membero `(,object . ,o) node-bindings)
                    (conde ((== predicates #f))
                           ((== predicates '()))
                           ((membero p predicates)))
                    (conde ((triple/eid db+id s p o)
                            (conde ((== relation #f))
                                   ((stringo relation) 
                                    (eprop db+id "relation" relation))))
                           ((fresh (id)
                              (k-triple id s p o)
                              (== db+id `(kg . ,id)))))
                    (== bindings `((,id . ,db+id) . ,bindings-rest))
                    (loop (cdr edges) bindings-rest)))))))))

(define (trapi-constraints constraints)
  (relation trapi-node-constraints-o (node)
    (let loop ((constraints constraints))
      (if (null? constraints)
          (== #t #t)
          (let* ((constraint (car constraints))
                 (id        (hash-ref constraint 'id #f))
                 (not?      (hash-ref constraint 'not #f))
                 (operator  (hash-ref constraint 'operator #f))
                 (enum      (hash-ref constraint 'enum #f))
                 (value     (hash-ref constraint 'value #f))
                 (unit-id   (hash-ref constraint 'unit_id #f))) ;?
            (fresh (val)
              (triple node id val)
              (case operator
                ((">")  (if not?
                            (<=o val value)
                            (<o value val)))
                (("<")  (if not?
                            (<=o val value)
                            (<o val value)))
                (("matches") (:== #t (val) (regexp-match value val)))
                (else (if not?
                          (=/= val value)
                          (== val value))))
              (loop (cdr constraints))))))))

(define (edge-id/reported db+eid)
  (let ((db     (car db+eid))
        (eid    (cdr db+eid)))
    (if (eq? db 'kg) (strlift eid) 
        (string-append (strlift db) "." (strlift eid)))))

(define (trapi-response-results results qgraph)
  (let-values (((is-set-nodes singleton-nodes)
                (partition (lambda (node) (hash-ref (cdr node) 'is_set #f))
                           (hash->list (hash-ref qgraph 'nodes)))))
    (if (null? is-set-nodes) 
        (transform-trapi-results results)
        (transform-trapi-results (group-sets results (map car singleton-nodes))))))

(define (transform-trapi-results results)
  (map (lambda (bindings)
         (hash 'node_bindings
               (make-hash
                (map (lambda (binding) 
                       (let ((node/s (cdr binding)))
                         `(,(car binding)
                           . ,(map (lambda (id) (hash 'id id))
                                   (if (list? node/s) node/s
                                       (list node/s))))))
                     (alist-ref bindings 'node_bindings '())))
               'edge_bindings
               (make-hash
                (map (lambda (ebinding)
                       (let ((edge/s (cdr ebinding)))
                         `(,(car ebinding)
                           . ,(map (lambda (db+id)
                                     (hash 'id (edge-id/reported db+id)))
                                   (if (list? edge/s) edge/s
                                       (list edge/s))))))
                     (alist-ref bindings 'edge_bindings '())))

               ;;; WEB: dummy score, until I implement a scoring algorithm
               'score
               42.01
               
               ))
       results))

(define (unique-bindings-values results key)
  (remove-duplicates
   (apply append
          (map
           (lambda (nb) (map cdr (alist-ref nb key #f)))
           results))))

(define (snake->camel str (capitalize? #f)) 
  (if (non-empty-string? str)
      (let ((first-letter (substring str 0 1))
            (rest-str (substring str 1 (string-length str))))
        (if (equal? first-letter "_")
            (snake->camel rest-str #t)
            (string-append (if capitalize?
                               (string-upcase first-letter) 
                               first-letter)
                           (snake->camel rest-str))))
      ""))

;; hack to ensure Biolink compliance for rtx2-20210204 and semmeddb
(define (biolinkify/predicate curie)
  (let ((curie (string-replace curie "," "")))
    (if (string-prefix? curie "biolink:") curie
        (string-append "biolink:" curie))))

;; hack to ensure Biolink compliance for rtx2-20210204 and semmeddb
(define (biolinkify/category curie)
  (if (string-prefix? curie "biolink:") curie
      (string-append "biolink:" 
                     (string-replace (snake->camel curie #t) "_" ""))))

(define (props-kv k+v)
  (let ((k (car k+v)) (v (cdr k+v)))
    (cond ((eq? k "predicate")
           `(predicate . ,(biolinkify/predicate v)))
          (else
           (cons (string->symbol k) v)))))

(define (attributes-kv keys)
  (lambda (k+v)
    (let ((k (car k+v)) (v (cdr k+v)))
      (make-hash
       `((attribute_type_id . ,(alist-ref keys k "miscellaneous"))
         (value_type_id . ,(alist-ref keys k "miscellaneous"))
         (original_attribute_name . ,(strlift k))
         (value . ,(strlift v)))))))

(define (trapi-response-knodes/edges results key new-key query attributes-query attributes-keys)
  (make-hash
   (map (lambda (node)
          `(,(new-key node)
            . ,(make-hash
                (append (let ((attributes (attributes-query node)))
                          (if (pair? attributes)
                              `((attributes . ,(map (attributes-kv attributes-keys) attributes))) '()))
                        (map props-kv (query node))))))
        (unique-bindings-values results key))))

(define (trapi-response-knodes results)
  (trapi-response-knodes/edges
   results 'node_bindings string->symbol
   ;; (lambda (node) 
   ;;   (run* prop
   ;;     (fresh (k v)
   ;;       (membero k trapi-response-node-properties)
   ;;       (== `(,k . ,v) prop)
   ;;       (cprop node k v))))
   (lambda (node)
     `(("name" . ,(car (run 1 v (cprop node "name" v)))) ; hack: only gets 1!
       ("categories" . ,(remove-duplicates
                         (map biolinkify/category (run* v (cprop node "category" v)))))))
   (lambda (node)
     (run* attribute
       (fresh (k v)
         (membero k (map car trapi-response-node-attributes))
         (== `(,k . ,v) attribute)
         (cprop node k v))))
   trapi-response-node-attributes))

(define (trapi-response-kedges results)
  (trapi-response-knodes/edges 
   results 'edge_bindings (compose symlift edge-id/reported)
   (lambda (node) 
     (let ((properties
            (run* prop
              (fresh (k v)
                (membero k trapi-response-edge-properties)
                (== `(,k . ,v) prop)
                (eprop node k v)))))
       (if (and (memf (lambda (k+v) (eq? (car k+v) "subject")) properties)
                (memf (lambda (k+v) (eq? (car k+v) "object")) properties))
           properties
           (let ((s+p (car (run 1 (s o) (edge node s o)))))
             `(("subject" . ,(car s+p))
               ("object" . ,(cadr s+p))
               . ,properties)))))
   (lambda (node)
     (run* attribute
       (fresh (k v)
         (membero k (map car trapi-response-edge-attributes))
         (== `(,k . ,v) attribute)
         (eprop node k v))))
   trapi-response-edge-attributes))

(define (group-sets results singleton-nodes)
  (define (get-nodes result)
    (sort (filter (lambda (node)
                    (member (car node) singleton-nodes))
                  ;; WEB  FIXME taking 'cdr' of unchecked 'assoc' result
                  (cdr (assoc 'node_bindings result)))
          string<?
          #:key (lambda (e) (symbol->string (car e)))))
  (define (nodes-equal? a b)
    (equal? (get-nodes a) (get-nodes b)))
  (define (combine-bindings results key)
    (foldl
     (lambda (result rst) 
       (dict-map result (lambda (id curie)
                          (remove-duplicates
                           (cons id (cons curie (alist-ref rst id '())))))))
     '()
     (map (lambda (result)
            ;; WEB  FIXME taking 'cdr' of unchecked 'assoc' result
            (cdr (assoc key result)))
          results)))
  (map (lambda (results)
         `((node_bindings . ,(combine-bindings results 'node_bindings))
           (edge_bindings . ,(combine-bindings results 'edge_bindings))))
       (group-by values results nodes-equal?)))
