;; deriv.scm: symbolic differentiation in Scheme, after SICP 2.3.2. Type
;; f(x) as an s-expression, or pick an example; Scheme differentiates it,
;; simplifies the result, prints both in ordinary notation and plots them.
;; Move over the plot and the tangent to f follows the pointer, with its
;; slope read off f'.
;;
;;	uitreefs -t Derivatives --dir ALPINE:#L chibi-scheme deriv.scm
;;
;; chibi-scheme is a Linux program here, from an Alpine tree run by h9's
;; Linux ABI, and it reaches the tree at $ui through R7RS's own file ports:
;; open-input-file on events and read-line, call-with-output-file for every
;; write. The expression in the input is read with read, so the program is
;; working on the same lists it is written in: deriv, simplify and the
;; infix printer are each one recursive walk over them.
;;
;; Shows: a Scheme client on R7RS small with no libraries, a list of
;; examples picked with select, a submit read from the input's value file,
;; a field error for a bad expression, a canvas drawn once per function
;; (grid, axes, labels and both curves as paths), and coalesced move events
;; answered with one canvas ctl write that moves the tangent, two dots and
;; the readout by id.   Needs: M4

(import (scheme base) (scheme char) (scheme cxr) (scheme read) (scheme write)
        (scheme file) (scheme inexact) (scheme process-context))

(define ui (or (get-environment-variable "ui") "/mnt/ui"))
(define (file p) (string-append ui "/win/main/" p))

;; put: one open, one write, one close. A ctl applies its lines at close.
(define (put p s) (call-with-output-file (file p) (lambda (o) (write-string s o))))
(define (get p)
  (call-with-input-file (file p)
    (lambda (in)
      (let loop ((acc '()))
        (let ((s (read-string 4096 in)))
          (if (eof-object? s) (apply string-append (reverse acc)) (loop (cons s acc))))))))
(define (lines . ls)
  (apply string-append (map (lambda (l) (string-append l "\n")) ls)))
(define (ctl . ls) (put "ctl" (apply lines ls)))
;; Plan 9 quoting: a quoted word, with '' for a quote inside it.
(define (q s)
  (let loop ((cs (string->list s)) (acc '(#\')))
    (cond ((null? cs) (list->string (reverse (cons #\' acc))))
          ((char=? (car cs) #\') (loop (cdr cs) (cons #\' (cons #\' acc))))
          (else (loop (cdr cs) (cons (car cs) acc))))))
(define (words s)
  (let loop ((cs (string->list s)) (w '()) (acc '()))
    (define (flush) (if (null? w) acc (cons (list->string (reverse w)) acc)))
    (cond ((null? cs) (reverse (flush)))
          ((char-whitespace? (car cs)) (loop (cdr cs) '() (flush)))
          (else (loop (cdr cs) (cons (car cs) w) acc)))))
(define (attr ws k)
  (let ((p (string-append k "=")))
    (let loop ((ws ws))
      (cond ((null? ws) #f)
            ((and (> (string-length (car ws)) (string-length p))
                  (string=? (substring (car ws) 0 (string-length p)) p))
             (substring (car ws) (string-length p) (string-length (car ws))))
            (else (loop (cdr ws)))))))

;; List helpers R7RS small leaves out.
(define (filter p l) (cond ((null? l) '()) ((p (car l)) (cons (car l) (filter p (cdr l)))) (else (filter p (cdr l)))))
(define (remove p l) (filter (lambda (x) (not (p x))) l))
(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))
(define (list-sort < l)
  (if (or (null? l) (null? (cdr l))) l
      (let loop ((a '()) (b '()) (l l))
        (if (null? l) (merge (list-sort < a) (list-sort < b) <)
            (loop b (cons (car l) a) (cdr l))))))
(define (merge a b <)
  (cond ((null? a) b) ((null? b) a)
        ((< (car b) (car a)) (cons (car b) (merge a (cdr b) <)))
        (else (cons (car a) (merge (cdr a) b <)))))

;;; The calculus. Expressions are numbers, x, pi, e, and lists:
;;; (+ a ...) (- a ...) (* a ...) (/ a b) (^ a b) and (f a) for
;;; sin cos tan exp log sqrt.

(define (const? e) (or (number? e) (and (symbol? e) (not (eq? e 'x)))))
(define (free-of-x? e)
  (cond ((pair? e) (and (free-of-x? (car e)) (free-of-x? (cdr e))))
        (else (not (eq? e 'x)))))

(define (deriv e)
  (cond
   ((eq? e 'x) 1)
   ((const? e) 0)
   (else
    (let ((op (car e)) (a (cdr e)))
      (case op
        ((+) `(+ ,@(map deriv a)))
        ((-) `(- ,@(map deriv a)))
        ;; the product rule, for any number of factors
        ((*) `(+ ,@(let loop ((before '()) (after a))
                     (if (null? after) '()
                         (cons `(* ,@(reverse before) ,(deriv (car after)) ,@(cdr after))
                               (loop (cons (car after) before) (cdr after)))))))
        ((/) (if (null? (cdr a))
                 (deriv `(/ 1 ,(car a)))
                 (let ((u (car a)) (v (cadr a)))
                   `(/ (- (* ,(deriv u) ,v) (* ,u ,(deriv v))) (^ ,v 2)))))
        ((^) (let ((u (car a)) (n (cadr a)))
               (if (free-of-x? n)
                   `(* ,n (^ ,u (- ,n 1)) ,(deriv u))
                   `(* (^ ,u ,n) (+ (* ,(deriv n) (log ,u)) (/ (* ,n ,(deriv u)) ,u))))))
        ((sin) `(* (cos ,(car a)) ,(deriv (car a))))
        ((cos) `(* (- (sin ,(car a))) ,(deriv (car a))))
        ((tan) `(/ ,(deriv (car a)) (^ (cos ,(car a)) 2)))
        ((exp) `(* (exp ,(car a)) ,(deriv (car a))))
        ((log) `(/ ,(deriv (car a)) ,(car a)))
        ((sqrt) `(/ ,(deriv (car a)) (* 2 (sqrt ,(car a)))))
        (else (error "can't differentiate" op)))))))

;; simplify: fold constants, drop 0 and 1 where they do nothing, flatten
;; nested sums and products, collect like terms (x + x is 2x) and like
;; factors (x·x is x²), cancel what a quotient has on both sides, and put
;; a product's number first and its x first after that.
(define (flatten op args)
  (apply append (map (lambda (a) (if (and (pair? a) (eq? (car a) op)) (cdr a) (list a))) args)))
(define (product fs) (cond ((null? fs) 1) ((null? (cdr fs)) (car fs)) (else `(* ,@fs))))
(define (factors e) (cond ((equal? e 1) '()) ((and (pair? e) (eq? (car e) '*)) (cdr e)) (else (list e))))
;; split-coef: e as (number . the rest), so 3x is (3 . x) and -x is (-1 . x)
(define (split-coef e)
  (cond ((number? e) (cons e 1))
        ((and (pair? e) (eq? (car e) '-) (null? (cddr e)))
         (let ((c (split-coef (cadr e)))) (cons (- (car c)) (cdr c))))
        ((and (pair? e) (eq? (car e) '*) (number? (cadr e))) (cons (cadr e) (product (cddr e))))
        (else (cons 1 e))))
(define (with-coef c r)
  (cond ((zero? c) 0) ((equal? r 1) c) ((= c 1) r) ((= c -1) `(- ,r))
        (else `(* ,c ,@(factors r)))))
(define (negate e)
  (if (and (pair? e) (eq? (car e) '+))
      `(+ ,@(map negate (cdr e)))
      (let ((c (split-coef e))) (with-coef (- (car c)) (cdr c)))))
;; powers: factors as (base . exponent), equal bases merged
(define (powers fs)
  (let loop ((fs fs) (acc '()))
    (if (null? fs) (reverse acc)
        (let* ((f (car fs))
               (b (if (and (pair? f) (eq? (car f) '^) (number? (caddr f))) (cadr f) f))
               (n (if (and (pair? f) (eq? (car f) '^) (number? (caddr f))) (caddr f) 1))
               (hit (assoc b acc)))
          (if hit (begin (set-cdr! hit (+ (cdr hit) n)) (loop (cdr fs) acc))
              (loop (cdr fs) (cons (cons b n) acc)))))))
(define (rank f)
  (let ((b (if (and (pair? f) (eq? (car f) '^)) (cadr f) f)))
    (cond ((number? f) 0) ((and (symbol? b) (not (eq? b 'x))) 1) ((eq? b 'x) 2)
          ((and (pair? f) (eq? (car f) '+)) 4) (else 3))))
(define (unpowers ps)
  (product (list-sort (lambda (a b) (< (rank a) (rank b)))
                      (filter (lambda (f) (not (equal? f 1)))
                              (map (lambda (p) (cond ((equal? (cdr p) 0) 1) ((equal? (cdr p) 1) (car p))
                                                     (else `(^ ,(car p) ,(cdr p)))))
                                   ps)))))
(define (sum ts)
  (let loop ((ts (flatten '+ ts)) (acc '()))
    (if (null? ts)
        (let* ((terms (filter (lambda (t) (not (equal? t 0)))
                              (map (lambda (p) (with-coef (cdr p) (car p))) (reverse acc))))
               (terms (append (remove number? terms) (filter number? terms))))
          (cond ((null? terms) 0) ((null? (cdr terms)) (car terms)) (else `(+ ,@terms))))
        (let* ((c (split-coef (car ts))) (hit (assoc (cdr c) acc)))
          (if hit (begin (set-cdr! hit (+ (cdr hit) (car c))) (loop (cdr ts) acc))
              (loop (cdr ts) (cons (cons (cdr c) (car c)) acc)))))))
(define (quotient-of u v)
  (let* ((cu (split-coef u)) (cv (split-coef v)) (c (/ (car cu) (car cv)))
         (pu (powers (factors (cdr cu)))) (pv (powers (factors (cdr cv)))))
    ;; cancel: a base on both sides loses the smaller exponent from each
    (for-each (lambda (p)
                (let ((hit (assoc (car p) pu)))
                  (when (and hit (real? (cdr hit)) (real? (cdr p)))
                    (let ((k (min (cdr hit) (cdr p))))
                      (set-cdr! hit (- (cdr hit) k)) (set-cdr! p (- (cdr p) k))))))
              pv)
    (let* ((frac (and (exact? c) (not (integer? c))))
           (num (with-coef (if frac (numerator c) c) (unpowers pu)))
           (den (with-coef (if frac (denominator c) 1) (unpowers pv))))
      (if (equal? den 1) num `(/ ,num ,den)))))
(define (simplify e)
  (if (not (pair? e)) e
      (let ((op (car e)) (a (map simplify (cdr e))))
        (case op
          ((+) (sum a))
          ((-) (if (null? (cdr a)) (negate (car a)) (sum (cons (car a) (map negate (cdr a))))))
          ((*) (let* ((fs (flatten '* a))
                      (q (let find ((fs fs)) (cond ((null? fs) #f)
                                                    ((and (pair? (car fs)) (eq? (caar fs) '/)) (car fs))
                                                    (else (find (cdr fs)))))))
                 (if q
                     ;; a quotient among the factors takes the rest into its top
                     (simplify `(/ (* ,@(remove (lambda (f) (eq? f q)) fs) ,(cadr q)) ,(caddr q)))
                     (let* ((cs (map split-coef fs))
                            (c (apply * (map car cs))))
                       (with-coef c (unpowers (powers (remove (lambda (r) (equal? r 1)) (flatten '* (map cdr cs))))))))))
          ((/) (cond ((null? (cdr a)) (simplify `(/ 1 ,(car a))))
                     ((equal? (car a) 0) 0)
                     ((equal? (cadr a) 0) `(/ ,(car a) 0))
                     (else (quotient-of (car a) (cadr a)))))
          ((^) (let ((u (car a)) (n (cadr a)))
                 (cond ((eq? u 'e) (simplify `(exp ,n)))
                       ((equal? n 0) 1)
                       ((equal? n 1) u)
                       ((and (number? u) (number? n) (exact? n) (integer? n)) (expt u n))
                       ;; (^ (^ u a) b) is (^ u (* a b))
                       ((and (pair? u) (eq? (car u) '^) (number? (caddr u)) (number? n))
                        (simplify `(^ ,(cadr u) ,(* (caddr u) n))))
                       (else `(^ ,u ,n)))))
          ((sqrt) (if (and (number? (car a)) (exact? (car a)) (exact-integer-sqrt? (car a)))
                      (exact (sqrt (car a))) `(sqrt ,(car a))))
          ((log) (cond ((equal? (car a) 1) 0) ((eq? (car a) 'e) 1)
                       ((and (pair? (car a)) (eq? (caar a) 'exp)) (cadar a))
                       (else `(log ,(car a)))))
          ((exp) (cond ((equal? (car a) 0) 1)
                       ((and (pair? (car a)) (eq? (caar a) 'log)) (cadar a))
                       (else `(exp ,(car a)))))
          (else `(,op ,@a))))))
(define (exact-integer-sqrt? n)
  (and (integer? n) (>= n 0) (let ((r (exact (floor (sqrt n))))) (= (* r r) n))))

;; value: the number e stands for at x, or #f where it has none.
(define (value e x)
  (define (v e)
    (cond ((number? e) e) ((eq? e 'x) x) ((eq? e 'pi) (acos -1)) ((eq? e 'e) (exp 1))
          ((symbol? e) (raise 'unbound))
          (else
           (let ((op (car e)) (a (map v (cdr e))))
             (case op
               ((+) (apply + a))
               ((-) (apply - a))
               ((*) (apply * a))
               ((/) (if (memv 0 (cdr a)) (raise 'domain) (apply / a)))
               ((^) (let ((r (expt (car a) (cadr a)))) (if (real? r) r (raise 'domain))))
               ((sin) (sin (car a))) ((cos) (cos (car a))) ((tan) (tan (car a)))
               ((exp) (exp (car a)))
               ((log) (if (> (car a) 0) (log (car a)) (raise 'domain)))
               ((sqrt) (if (>= (car a) 0) (sqrt (car a)) (raise 'domain)))
               (else (raise 'unbound)))))))
  (guard (c (#t #f))
    (let ((r (inexact (v e))))
      (and (real? r) (ok-num? r) r))))
(define (ok-num? r) (and (= r r) (< (abs r) 1e300)))

;; check: an error string if e isn't an expression this program knows.
(define (check e)
  (cond ((number? e) #f)
        ((memq e '(x pi e)) #f)
        ((symbol? e) (string-append "unknown name " (symbol->string e)))
        ((not (list? e)) "not an expression")
        ((null? e) "empty list")
        ((not (assq (car e) arity)) (string-append "unknown operator " (show (car e))))
        (else
         (let* ((n (length (cdr e))) (want (cdr (assq (car e) arity))))
           (cond ((< n (car want)) (string-append (symbol->string (car e)) " needs more arguments"))
                 ((and (cdr want) (> n (cdr want))) (string-append (symbol->string (car e)) " takes " (number->string (cdr want))))
                 (else (let loop ((a (cdr e)))
                         (cond ((null? a) #f) ((check (car a)) => (lambda (m) m)) (else (loop (cdr a)))))))))))
(define arity
  '((+ 1 . #f) (- 1 . #f) (* 1 . #f) (/ 1 . 2) (^ 2 . 2)
    (sin 1 . 1) (cos 1 . 1) (tan 1 . 1) (exp 1 . 1) (log 1 . 1) (sqrt 1 . 1)))
(define (show v) (let ((o (open-output-string))) (write v o) (get-output-string o)))

;;; Ordinary notation: x·sin(x) + cos(x), 3x², e^(−x²/2).

(define (fixed v n)
  ;; v with at most n decimals, trailing zeros dropped
  (let* ((m (expt 10 n)) (i (exact (round (* (abs v) m))))
         (int (quotient i m)) (frac (remainder i m))
         (fs (let ((s (number->string frac)))
               (string-append (make-string (- n (string-length s)) #\0) s)))
         (fs (let trim ((s fs)) (if (and (> (string-length s) 0) (char=? (string-ref s (- (string-length s) 1)) #\0))
                                    (trim (substring s 0 (- (string-length s) 1))) s))))
    (string-append (if (and (< v 0) (> i 0)) "-" "") (number->string int)
                   (if (string=? fs "") "" (string-append "." fs)))))
;; pretty: a typeset minus sign in place of a leading hyphen
(define (pretty s)
  (if (and (> (string-length s) 0) (char=? (string-ref s 0) #\-))
      (string-append "−" (substring s 1 (string-length s))) s))
(define (num n)
  (cond ((and (exact? n) (integer? n)) (if (< n 0) (string-append "−" (number->string (- n))) (number->string n)))
        ((exact? n) (string-append (if (< n 0) "−" "") (number->string (abs (numerator n))) "/" (number->string (denominator n))))
        (else (pretty (fixed n 4)))))
(define sup "⁰¹²³⁴⁵⁶⁷⁸⁹")
(define (superscript n)
  (string-append (if (< n 0) "⁻" "")
                 (list->string (map (lambda (c) (string-ref sup (- (char->integer c) 48)))
                                    (string->list (number->string (abs n)))))))
(define (prec e)
  (cond ((number? e) (if (or (negative? e) (not (integer? e))) 2 9))
        ((symbol? e) 9)
        (else (case (car e) ((+) 1) ((-) (if (null? (cddr e)) 3 1)) ((* /) 2) ((^) 4) (else 9)))))
(define (wrap e p) (if (< (prec e) p) (string-append "(" (infix e) ")") (infix e)))
(define (unary-minus? e) (and (pair? e) (eq? (car e) '-) (null? (cddr e))))
(define (letter-first? e)
  (or (symbol? e)
      (and (pair? e) (eq? (car e) '^) (symbol? (cadr e)))
      (and (pair? e) (memq (car e) '(sin cos tan exp log sqrt)))))
(define (infix e)
  (cond
   ((number? e) (num e))
   ((eq? e 'pi) "π")
   ((symbol? e) (symbol->string e))
   (else
    (let ((op (car e)) (a (cdr e)))
      (case op
        ((+) (let loop ((s (infix (car a))) (r (cdr a)))
               (cond ((null? r) s)
                     ((unary-minus? (car r)) (loop (string-append s " − " (wrap (cadar r) 2)) (cdr r)))
                     ((and (number? (car r)) (negative? (car r))) (loop (string-append s " − " (num (- (car r)))) (cdr r)))
                     ((and (pair? (car r)) (eq? (caar r) '*) (number? (cadar r)) (negative? (cadar r)))
                      (loop (string-append s " − " (wrap (negate (car r)) 2)) (cdr r)))
                     (else (loop (string-append s " + " (wrap (car r) 1)) (cdr r))))))
        ((-) (if (null? (cdr a))
                 (string-append "−" (wrap (car a) 2))
                 (let loop ((s (wrap (car a) 1)) (r (cdr a)))
                   (if (null? r) s (loop (string-append s " − " (wrap (car r) 2)) (cdr r))))))
        ((*) (let loop ((s (wrap (car a) 2)) (prev (car a)) (r (cdr a)))
               (if (null? r) s
                   (loop (string-append s (if (and (exact-integer? prev) (letter-first? (car r))) "" "·")
                                        (wrap (car r) 3))
                         (car r) (cdr r)))))
        ((/) (if (null? (cdr a)) (string-append "1/" (wrap (car a) 3))
                 (string-append (wrap (car a) 2) "/" (wrap (cadr a) 3))))
        ((^) (let ((u (car a)) (n (cadr a)))
               (cond ((and (eq? u 'e)) (string-append "e^" (wrap n 5)))
                     ((and (number? n) (exact? n) (integer? n)) (string-append (wrap u 5) (superscript n)))
                     (else (string-append (wrap u 5) "^" (wrap n 5))))))
        ((sqrt) (string-append "√" (wrap (car a) 5)))
        ((exp) (string-append "e^" (wrap (car a) 5)))
        (else (string-append (symbol->string op) "(" (infix (car a)) ")")))))))

;;; The screen.

(define examples
  ;; id  label  f  x range  [y range, where the automatic one won't do]
  '((prod "x·sin(x)" (* x (sin x)) -7 7)
    (cubic "Cubic" (- (^ x 3) (* 3 x)) -2.5 2.5)
    (bell "Bell curve" (exp (- (/ (^ x 2) 2))) -4 4)
    (chain "sin(x²)" (sin (^ x 2)) -3 3)
    (sinc "sin(x)/x" (/ (sin x) x) -12 12)
    (log "x·log(x)" (* x (log x)) -0.5 3)
    (tan "tan(x)" (tan x) -4 4 -6 6)
    (xx "xˣ" (^ x x) 0 2)
    (hyp "√(1 + x²)" (sqrt (+ 1 (^ x 2))) -4 4)))

(ctl "set . title=Derivatives size=960,660 min=820,600 pos=center")
(put "tree" (lines
"div root  : h_flex items_stretch size_full bg=background"
"  div side  : v_flex w=210 p=12 gap=8 border_r_1 border_color=border bg=muted"
"    text h  text=Examples  : text_sm font_semibold px=4"
"    list ex  selectable  tag=ex  : flex_1"
"    text help  text='+ − * / ^, sin cos tan exp log sqrt, x, pi, e'  : text_xs text_color=muted_foreground px=4"
"  div page  : v_flex flex_1 p=20 gap=12"
"    form in  tag=expr"
"      field e  label='f(x), as a Scheme expression'"
"        input f  : font_family=monospace"
"    div res  : v_flex gap=4"
"      div f  : h_flex gap=12 items_center"
"        text k  text='f(x)'  : w=60 text_sm font_semibold text_color=info"
"        text v  : text_lg"
"      div d  : h_flex gap=12 items_center"
"        text k  text='f′(x)'  : w=60 text_sm font_semibold text_color=danger"
"        text v  : text_lg"
"      div s  : h_flex gap=12 items_center"
"        text k  text=Scheme  : w=60 text_xs text_color=muted_foreground"
"        text v  : text_xs font_family=monospace text_color=muted_foreground truncate"
"    canvas c  tag=plot  on=move  : w=680 h=380 rounded_lg"))
(put "side/ex/items"
     (apply lines (map (lambda (x) (string-append (symbol->string (car x)) " " (q (cadr x)))) examples)))

;;; The plot. W by H, with a margin; x0..x1 across, y0..y1 up.
(define W 680) (define H 380) (define M 36)
(define x0 -5) (define x1 5) (define y0 -1) (define y1 1)
(define f 'x) (define df 1)
(define fixed-y #f)   ; (lo . hi) from the example, or #f
(define (px x) (+ M (* (- W M M) (/ (- x x0) (- x1 x0)))))
(define (py y) (- H M (* (- H M M) (/ (- y y0) (- y1 y0)))))
(define (r1 v) (fixed v 1))
(define (pt x y) (string-append (r1 (px x)) "," (r1 (py y))))

(define (nice-step span)
  (let* ((raw (/ span 6)) (p (expt 10 (floor (/ (log raw) (log 10))))) (m (/ raw p)))
    (* p (cond ((< m 1.5) 1) ((< m 3.5) 2) ((< m 7.5) 5) (else 10)))))
(define (ticks lo hi)
  (let ((s (nice-step (- hi lo))))
    (let loop ((t (* s (ceiling (/ lo s)))) (acc '()))
      (if (> t (+ hi 1e-9)) (reverse acc) (loop (+ t s) (cons t acc))))))

(define N 300)
(define (samples g)
  (let loop ((i 0) (acc '()))
    (if (> i N) (reverse acc)
        (let ((x (+ x0 (* (- x1 x0) (/ i N)))))
          (loop (+ i 1) (cons (cons x (value g x)) acc))))))
;; a path through the samples, broken where g has no value or leaves the
;; plot by a long way (tan's asymptotes)
(define (path-of ss)
  (let loop ((ss ss) (pen #f) (acc '()))
    (if (null? ss) (apply string-append (reverse acc))
        (let* ((x (caar ss)) (y (cdar ss))
               (ok (and y (< (- y0 (* 3 (- y1 y0))) y (+ y1 (* 3 (- y1 y0)))))))
          (if ok
              (loop (cdr ss) #t (cons (string-append (if pen " L" " M") (pt x y)) acc))
              (loop (cdr ss) #f acc))))))

;; the y range: what most of f and f' cover, so a pole doesn't flatten
;; the rest
(define (y-range fs dfs)
  (let* ((vs (list-sort < (filter (lambda (v) v) (map cdr (append fs dfs)))))
         (n (length vs)))
    (if (< n 2) (values -1 1)
        (let* ((lo (list-ref vs (exact (floor (* n 0.03)))))
               (hi (list-ref vs (exact (floor (* n 0.97)))))
               (lo (min lo 0)) (hi (max hi 0))
               (pad (* 0.12 (max (- hi lo) 1e-6))))
          (values (- lo pad) (+ hi pad))))))
(define (label v) (num (if (and (integer? v) (< (abs v) 1e9)) (exact (round v)) v)))
(define (plot)
  (let ((fs (samples f)) (dfs (samples df)))
    (if fixed-y
        (begin (set! y0 (car fixed-y)) (set! y1 (cdr fixed-y)))
        (call-with-values (lambda () (y-range fs dfs))
          (lambda (lo hi) (set! y0 lo) (set! y1 hi))))
    (let* ((xt (ticks x0 x1)) (yt (ticks y0 y1))
           (ax (if (< y0 0 y1) 0 y0)) (ay (if (< x0 0 x1) 0 x0)))
      (put "page/c/ops"
           (apply lines
                  (append
                   (list (string-append "rect bg 0 0 " (number->string W) " " (number->string H) " fill=background border=border radius=8"))
                   (map (lambda (t i) (string-append "path gx" (number->string i) " M" (pt t y0) " L" (pt t y1) " stroke=border"))
                        xt (iota (length xt)))
                   (map (lambda (t i) (string-append "path gy" (number->string i) " M" (pt x0 t) " L" (pt x1 t) " stroke=border"))
                        yt (iota (length yt)))
                   (list (string-append "path ax M" (pt x0 ax) " L" (pt x1 ax) " stroke=muted_foreground width=1.5")
                         (string-append "path ay M" (pt ay y0) " L" (pt ay y1) " stroke=muted_foreground width=1.5"))
                   (map (lambda (t i) (string-append "text lx" (number->string i) " " (r1 (- (px t) 6)) " " (r1 (+ (py y0) 8)) " "
                                                     (q (label t)) " size=11 color=muted_foreground"))
                        xt (iota (length xt)))
                   (map (lambda (t i) (string-append "text ly" (number->string i) " 4 " (r1 (- (py t) 7)) " "
                                                     (q (label t)) " size=11 color=muted_foreground"))
                        yt (iota (length yt)))
                   (list (string-append "path df" (path-of dfs) " stroke=danger width=2 cap=round")
                         (string-append "path f" (path-of fs) " stroke=info width=2.5 cap=round")
                         ;; the tangent, its point, f' at x, and the readout:
                         ;; drawn invisible until the pointer is over the plot
                         "path tan M0,0 L0,0 stroke=success width=1.5 opacity=0"
                         "circle dp 0 0 4 fill=danger opacity=0"
                         "circle fp 0 0 5 fill=info border=background opacity=0"
                         (string-append "rect rb " (number->string (- W 250)) " 10 238 26 fill=muted radius=6 opacity=0")
                         (string-append "text rd " (number->string (- W 240)) " 15 '' size=12 color=foreground opacity=0")
                         (string-append "text lf " (number->string (+ M 8)) " 12 f size=13 weight=bold color=info")
                         (string-append "text ld " (number->string (+ M 26)) " 12 f′ size=13 weight=bold color=danger"))))))))

;; tangent: at canvas x, move the tangent line, the dots and the readout
(define (tangent cx)
  (let* ((x (+ x0 (* (- x1 x0) (/ (- cx M) (- W M M)))))
         (y (value f x)) (s (value df x)))
    (if (and y s (<= x0 x x1))
        (let ((t0 (- x (* 0.25 (- x1 x0)))) (t1 (+ x (* 0.25 (- x1 x0)))))
          (put "page/c/ctl"
               (lines
                (string-append "set tan M" (pt t0 (+ y (* s (- t0 x)))) " L" (pt t1 (+ y (* s (- t1 x)))) " opacity=1")
                (string-append "set fp " (r1 (px x)) " " (r1 (py y)) " opacity=1")
                (string-append "set dp " (r1 (px x)) " " (r1 (py (max y0 (min y1 s)))) " opacity=" (if (<= y0 s y1) "1" "0"))
                "set rb opacity=0.9"
                (string-append "set rd " (number->string (- W 240)) " 15 "
                               (q (string-append "x = " (pretty (fixed x 2)) "   f = " (pretty (fixed y 3)) "   f′ = " (pretty (fixed s 3))))
                               " opacity=1"))))
        (put "page/c/ctl" (lines "set tan opacity=0" "set fp opacity=0" "set dp opacity=0" "set rb opacity=0" "set rd opacity=0")))))

;; use: differentiate e and show everything, or say what's wrong with it
(define (use e)
  (let ((bad (check e)))
    (if bad
        (ctl (string-append "set page/in/e error=" (q bad)))
        (let ((d (simplify (deriv e))))
          (set! f (simplify e)) (set! df d)
          (ctl "set page/in/e error="
               (string-append "set page/res/f/v text=" (q (infix f)))
               (string-append "set page/res/d/v text=" (q (infix d)))
               (string-append "set page/res/s/v text=" (q (show d))))
          (plot)))))
(define (pick id)
  (let ((x (assq (string->symbol id) examples)))
    (when x
      (set! x0 (cadddr x)) (set! x1 (car (cddddr x)))
      (set! fixed-y (let ((y (cdr (cddddr x)))) (and (pair? y) (cons (car y) (cadr y)))))
      (ctl (string-append "set page/in/e/f value=" (q (show (caddr x)))))
      (use (caddr x)))))
(define (typed)
  ;; read gives the list itself; a second read must find nothing more
  (let* ((p (open-input-string (get "page/in/e/f/value")))
         (e (guard (c (#t 'unreadable)) (read p)))
         (more (guard (c (#t #f)) (eof-object? (read p)))))
    (cond ((eq? e 'unreadable) (ctl "set page/in/e error='not an s-expression'"))
          ((eof-object? e) (ctl "set page/in/e error='type an expression, like (* x (sin x))'"))
          ((not more) (ctl "set page/in/e error='one expression, please'"))
          (else (set! fixed-y #f) (use e)))))

(ctl "set side/ex value=prod")
(pick "prod")

(define events (open-input-file (string-append ui "/events")))
(let loop ()
  (let ((l (read-line events)))
    (unless (eof-object? l)
      (let* ((w (words l)) (name (car w)) (key (if (pair? (cdr w)) (cadr w) "-")))
        (cond
         ((equal? (attr w "via") "ctl") #f)
         ((and (string=? name "select") (string=? key "ex"))
          (let ((v (attr w "value"))) (when v (pick v))))
         ((and (string=? name "submit") (string=? key "expr")) (typed))
         ((and (string=? name "move") (string=? key "plot"))
          (let ((x (attr w "x"))) (when x (tangent (string->number x)))))))
      (loop))))
