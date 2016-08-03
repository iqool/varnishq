;; =============================================================================
;;                                VARNISHQ
;; =============================================================================

(in-package #:varnishq)

;; ============================================================================
;; STUFF 
;; ============================================================================

(defmacro aif (test then &optional else)
  `(let ((it ,test))
     (if it ,then ,else)))

(defun flatten-opnds (l)
"sammelt alle operanden-atome einer [verschachtelten] Liste zusammen"
  (if l 
      (if (atom l) 
	  (list l) 
	  (mapcan #'flatten-opnds (cdr l)))))

;; =============================================================================
;; VARNISH-TAGS
;; =============================================================================

(defparameter *tags*
   '(Backend BackendClose BackendOpen BackendReuse Backend_healt CLI
     Debug ExpBan ExpKill Fetcherror Fetch_Body Gzip Hash Hit Interrupted
     ObjHeader ObjProtocol ObjResponse ReqEnd ReqStart RxHeader
     RxProtocol RxRequest RxResponse RxStatus RxURL SessionClose
     SessionOpen StatSess TTL TxHeader TxProtocol TxRequest TxResponse
     TxStatus TxURL VCL_acl VCL_call VCL_return WorkThread))

(defparameter *multiple-tags* 
  '(GZIP OBJRESPONSE OBJPROTOCOL BACKEND HIT VCL_ACL OBJHEADER TTL TXHEADER
				VCL_RETURN HASH VCL_CALL RXHEADER))

(defparameter *single-tags* 
  (set-difference *tags* *multiple-tags*))

(defparameter *integer-tags* 
;  '(RxStatus TxStatus Length Hit))
  '(RxStatus TxStatus Length))

;; =============================================================================
;; STREAMS
;; =============================================================================

(defun vlog-stream (&optional filename)
  "liefert einen stream, der den Prozess varnishlog enthält"
  (let ((options (if filename (list "-r" filename))))
    (sb-ext:process-output 
     (sb-ext:run-program "varnishlog" options 
                         :wait   nil
                         :search t 
                         :output :stream
                         :external-format '(:utf-8 :replacement #\?)))))

(defun live-stream ()
  "liefert einen stream, der den Prozess varnishlog enthält"
  (sb-ext:process-output 
   (sb-ext:run-program "varnishlog" '() 
		       :wait   nil
		       :search t 
		       :output :stream
		       :external-format '(:utf-8 :replacement #\?))))

(defun logfile-stream (name)
  "liefert eine datei als stream"
  (let ((stream (open name :external-format '(:utf-8 :replacement #\?))))
    stream))

;; =============================================================================
;; PARSING
;; =============================================================================

(defun parse (line)
  "eine Zeile varnishlog parsen. liefert eine liste"
  (let ((thread (parse-integer (string-trim " " (subseq line 0 5))))
 	(tag    (intern (string-upcase (string-trim " " (subseq line 6 (+ 6 12))))))
 	(code   (intern (string-upcase (subseq line 19 (+ 19 1)))))
 	(data   (subseq line 21)))
     (values thread tag code data)))

;; =============================================================================
;; LOGLINE-ACCESSORS
;; =============================================================================

(defun thread (x) "thread-# eines Satzes" (nth 0 x))
(defun tag (x)  "Tag eines Satzes" (nth 1 x))
(defun code (x) "Code eines Satzes" (nth 2 x))
(defun data (x) "datenfeld eines Satzes" (nth 3 x))

;; =============================================================================
;; ITERATORS
;; =============================================================================

(defun iterator (s); Zeilen-Iterator eines Streams erstellen.
"stream->(->request)"
  (lambda ()
    (ignore-errors (read-line s nil 'eof))))

(defun limited-iterator (s &key (maximum 0))
; Zeilen-Iterator eines Streams erstellen. Liefert maximum Zeilen und
; dann NIL. Kann einmal benutzt werden um sich die limitierungen bei
; avg, chart etc zu sparen
  "stream->(->request)"
  (let ((n maximum))
    (lambda ()
      (decf n)
      (if (> n 0)
          (ignore-errors (read-line s nil 'eof))))))


(defun varnish-request-aggregator (source)
"(->request) -> (->request)"
  (let ((threads (make-array (expt 2 15) :initial-element nil)))
    (lambda ()
	(loop for line = (funcall source) 
	   when (eq 'eof line) return 'eof
	   when (and (> (length line) 0 ) (eq  #\  (character (subseq line 0 1))))
	   do (progn
		(multiple-value-bind (thread tag code data) (parse line)
		  (when (> thread 0)
			(progn
			  (push (list thread tag code data) (aref threads thread))
			  (when (or (string= tag 'ReqEnd)
				    (string= tag 'BackendClose)
				    (string= tag 'BackendReuse))
			    (let ((request (reverse (aref threads thread))))
			      (setf (aref threads thread) nil)
			      (return request)))))))))))

(defun vlog (&rest args)
  ;; Finalize kann weder mit dem Prozess noch mit dem Stream arbeiten,
  ;; da diese sich scheinbar gegenseitig festhalten. Es bleibt
  ;; scheibar nur die Möglichkeit die Closure "iterator" zu
  ;; finalisieren, indem diese an den Stream ein close schickt, was
  ;; dann wie gewünscht zum Beenden des varnishlog-prozesses führt
  (let* ((ls (apply #'vlog-stream args))
	 (it (iterator ls)))
    (sb-ext:finalize it (lambda () 
			  (format *standard-output* "~&'varnishlog' closure abandoned~%") 
			  (close ls)))
    (varnish-request-aggregator it)))

(defun live() (vlog))

(defun file (name) 
  (let* ((ls (logfile-stream name))
	 (it (iterator ls)))
;; ob finalisierung hier erforderlich ist, ist nicht ganz klar. Aber sicher ist sicher.
    (sb-ext:finalize it (lambda () 
			  (format *standard-output* "~%logfile closure abandoned") 
			  (close ls)))
    (varnish-request-aggregator it)))

(defun find-varnish-date (stream)
  "search next time stamp in varnish logfile" 
  (loop 
     for line = (read-line stream nil)
     until      (or (null line) (search "ReqEnd" line))
     finally    (return (nth-num 2 line))))

(defun find-last-varnish-date (stream)
  "search last time stamp in logfile starting from actual position" 
  (loop
     with endtime
     for line = (read-line stream nil)
     until      (null line) 
     if         (search "ReqEnd" line)
     do (setq endtime  (nth-num 2 line))
     finally    (return endtime)))


(defun logfile-stream-timerange (s)
  "determine the timerange of a varnish logfile. Return the integer
unix epoch of start, the integer unix epoch of end and a readable
String of the time-range"
  (let ((old-position (file-position s)))
    (file-position s 0)
    (let ((starttime (truncate (find-varnish-date s))))
      (file-position s (max 0 (- (file-length s) 100000)))
      (let ((endtime (truncate (find-last-varnish-date s))))
	(file-position s old-position)
	(values starttime endtime
		(concatenate 'string (time-string starttime) " --> " (time-string endtime)))))))
    
(defun logfile-timerange (filename)
    (with-open-file (s filename)
      (logfile-stream-timerange s)))

(defun position-at-date (epoch stream start end last-read)
  "position a given logfile-stream at a specific unix epoch"
  (multiple-value-bind (first-timestamp last-timestamp)
      (logfile-stream-timerange stream)
;;    (print (list first-timestamp epoch last-timestamp))
    (assert (< first-timestamp epoch last-timestamp))
    (let ((mid (truncate (+ start end) 2)))
      (file-position stream mid)
      (let ((date (find-varnish-date stream)))
	 (if (= last-read date)
	     mid
	     (if (< epoch date) 
		 (position-at-date epoch stream start mid date)
		 (position-at-date epoch stream mid end date)))))))

(defun file-starting-at (name &optional start-epoch) 
  "open varnishlog file at a given epoch"
  (let* ((ls (logfile-stream name))
	 (it (iterator ls)))
    (let ((len (file-length ls)))
      (when start-epoch
	(let ((pos (position-at-date start-epoch ls 0 len 0)))
	  (format t "Starting at Byte ~a (~,1f %)~%" 
		  pos (* 100.0 (/ pos len))))))

    (sb-ext:finalize it (lambda () 
			  (format *standard-output* "~%logfile closure abandoned") 
			  (close ls)))
    (varnish-request-aggregator it)))

;; =============================================================================
;; TOOLS
;; =============================================================================

(defun find-tag-data (tag req) 
  (let ((value
	 (loop 
	    for line in req 
	    when (eq (tag line) tag) 
	    return (data line))))
    (if (member tag *integer-tags*) 
	(if value (parse-integer value)
	    0)
	(if value value 
	    ""))))

;; =============================================================================
;; DOMAIN SPECIFIC LANGUAGE   -   MACROS
;; =============================================================================

(defmacro collect (symbols body)
  (let ((return-list 
	 (mapcar (lambda (i) 
		   (if (member i *single-tags*)
		       (if (member i *integer-tags*)
			   (list 'parse-integer (list 'concatenate ''string "0" (list 'car i)))
			   (list 'car i)) 
		       i)) 
		 symbols)))
    (list 'multiple-value-bind
	  symbols
	  (append
	   `(loop for (thrd tg tp dt) in request)
	   (loop for i in symbols append
		`(when (eq tg ',i) collect dt into ,i))
	   `(finally (return (values ,@return-list))))
	  body)))
  
(defmacro where (expr source)
  "bindet für jeden Request alle in expr aufgeführten *single-tags*
als Einzelwerte an die entsprechenden Symbole und die aufgeführten
*multiple-tags* als Listen an die Symbole. Wertet unter dieser
Umgebung expr aus. Falls sich true ergibt, wird der betreffende
Request zurück gegeben."
  (let* ((src (gensym))
	 (used-tags (intersection (remove-duplicates (flatten-opnds expr)) *tags*)))
    `(let ((,src ,source))
       (lambda ()
	 (loop 
	    for request = (funcall ,src) do
	      (if (eq 'eof request) 
		  (return 'eof))
	      (collect ,used-tags
		(if ,expr
		    (return request))))))))

(defmacro app (expr source)
  "Wende einen ausdruck auf den request an: zB (dump (app (first
request) (live))) zeigt die erste Zeile von jedem request"
  (let ((src (gensym)))
    `(let ((,src ,source))
       (lambda ()
	 (let ((request (funcall ,src)))
	   (if (eq 'eof request)
	       'eof
	       ,expr))))))

(defmacro select (expr source)
  "wähle die Zeilen eines Requests aus, die einer Bedingung genügen:
zB (dump (select (eq tag 'hash (live))). Zeigt Zeilen, deren Tag 'Hash
heisst. Belegt dabei die Variablen tag, code und data. Dient der
Auswahl der Zeilen eines requests."
  `(app (loop for line in request
	   when line
	   when (let ((tag (tag line)) 
		      (code (code line))
		      (data (data line)))
		  (declare (ignore tag code data))
		  ,expr)
	   collect line) ,source))


(defmacro select-begin-w/ (expr source)
  "wähle die Zeilen eines Requests aus, die mit der Zeile beginnen,
die einer Bedingung genügt."
  `(app (loop for rest = request then (cdr rest)
           for line = (car rest)
	   when line
	   when (let ((tag (tag line)) 
		      (code (code line))
		      (data (data line)))
		  (declare (ignore tag code data))
		  ,expr)
	   do (return rest)) ,source))

(defmacro select-end-w/ (expr source)
  "wähle die Zeilen eines Requests aus, die mit der Zeile enden,
die einer Bedingung genügt."
  `(app (reverse (loop for rest = (reverse request) then (cdr rest)
           for line = (car rest)
	   when line
	   when (let ((tag (tag line)) 
		      (code (code line))
		      (data (data line)))
		  (declare (ignore tag code data))
		  ,expr)
	   do (return rest))) ,source))


(defmacro select-1st (expr source)
  "wähle die erste Zeile eines Requests aus, die einer Bedingung
genügt:"
 `(app (loop for rest = request then (cdr rest)
           for line = (car rest)
	   when line
	   when (let ((tag (tag line)) 
		      (code (code line))
		      (data (data line)))
		  (declare (ignore tag code data))
		  ,expr)
	   do (return (list line))) ,source))


(defmacro select-last (expr source)
  "wähle die erste Zeile eines Requests aus, die einer Bedingung
genügt:"
 `(app (loop for rest = (reverse request) then (cdr rest)
           for line = (car rest)
	   when line
	   when (let ((tag (tag line)) 
		      (code (code line))
		      (data (data line)))
		  (declare (ignore tag code data))
		  ,expr)
	   do (return (list line))) ,source))

;; FIXIT Statt der ganzen -1st,-lst,-begin-w/ - Zauberei könnte ein
;; Keyword-parameter mit den Werten :all :first :last :till :from
;; helfen

(defmacro type-is (a)
  "condition: 'request type is.. (syntactic sugar)" 
    `(and (third request) (eq ,a (code (third request)))))


(loop 
   for func in '(rxheader txheader objheader)
   collect 
     (eval 
      `(defmacro ,func (name)
	 (let ((nam (gensym)))
	   `(block header-ext
	      (let ((,nam ,name))
		(let ((scanner (cl-ppcre:create-scanner (concatenate 'string "^" ,nam ": (.*)$")
							:case-insensitive-mode t)))
		  (loop for l in request do
		       (when (eq (tag l) ',',func)
			 (let ((val (dissect  scanner (data l))))
			   (if val (return-from header-ext (aref  val 0)))))))))))))

;; =============================================================================
;; DOMAIN SPECIFIC LANGUAGE   -   FUNCTIONS
;; =============================================================================

(defun max-age (r &optional (default nil)) 
  (loop for l in r do 
       (let ((n (dissect "^Cache-Control: max-age=(\\d+)" (data l))))
	 (if n (return-from max-age (parse-integer (aref n 0))))))
  default)

(defun take (n source)
  "(n, (->request)) -> *request"
  (loop 
     for i from 1 to n as r = (funcall source) until (eq 'eof r)
     collect r))

(defun select-tag (tag source)
  (assert (member tag *tags*))
  (app (remove-if-not 
	(lambda (line) (eq (tag line) tag)) 
	request)
       source))

(defun select-tags (tags source)
  (assert (every (lambda (a) (member a *tags*)) tags))
"Eine Menge von Tags abfiltern (=> Projektion)"
  (app (remove-if-not 
	(lambda (line) (member (tag line) tags))
	request)
       source))

(defun inc-hash (hk htab)
  "inkrementiere einen hashtabellen-eintrag. Falls der Eintrag noch
nicht existiert, erstelle ihn mit dem Wert 1"
  (if (gethash hk htab)
      (incf (gethash hk htab))
      (setf (gethash hk htab) 1)))

(defmacro cnt (n expr source)
  (let ((src (gensym))
	(used-tags (intersection (remove-duplicates (flatten-opnds expr)) *tags*)))
    `(let ((,src ,source)
	   (nn ,n)
	   (htab (make-hash-table :test #'equal )))
	 (loop
	    for request = (funcall ,src)
	    for i from 1 to nn 
	    until (eq 'eof request) do
	      (collect ,used-tags
		(inc-hash ,expr htab))
	    finally (return (let ((res nil)) 
;				  (hc (hash-table-count htab))) 
			      (maphash (lambda (k v) (push (list v (* 100.0 (/ v (- i 1))) k) res)) 
				       htab)
			      (sort res #'> :key #'car)))))))

(defmacro avg (n expr source)
  "Durchschnitt von N Werten aus SOURCE, die von von EXPR geliefert werden" 
  (let ((src (gensym))
	(used-tags (intersection (remove-duplicates (flatten-opnds expr)) *tags*)))
    `(let ((,src ,source)
	   (nn ,n)
	   (total 0)
           (number 0))
	 (loop
	    for request = (funcall ,src)
	    for i from 1 to nn 
	    until (eq 'eof request) 
            do (collect ,used-tags
                       (progn
                         (incf total ,expr)
                         (incf number)))
	    finally (return (/ total number))))))

(defmacro agg (n expr source)
  "Aggregiere N Werte aus SOURCE in einer Liste, die Werte werden von
der Funktion EXPR geliefert"
  (let ((src (gensym))
	(used-tags (intersection (remove-duplicates (flatten-opnds expr)) 
				 *tags*)))
    `(let ((,src ,source)
	   (nn ,n)
           (agg))
	 (loop
	    for request = (funcall ,src)
	    for i from 1 to nn 
	    until (eq 'eof request) do
              (collect ,used-tags
                       (setq agg (cons ,expr agg)))
	    finally (return agg)))))


(defun statistical-data (value-list)
  "Anzahl, Summe, Durchschnitt und Standardabbweichung einer Liste von Werten"
  (let* ((sum (apply #'+ value-list)) 
         (n (length value-list)) 
         (avg (/ sum n)) 
         (sd (sqrt (/ (reduce (lambda (sumsq x) (+ sumsq (expt (- x avg) 2))) 
                              value-list 
                              :initial-value 0) n)))) 
    (values n sum avg sd)))

(defmacro any (expr)
  "Beispiel: (dmp (where (any (contains rxheader "888")) (live)))"
  (let ((tags-used (intersection (remove-duplicates (flatten-opnds expr)) *multiple-tags*)))
    (assert tags-used (expr) 
	    "The subexpression ~S contains no multiple-tag" expr)
    (assert (eql 1 (length tags-used)) (expr) 
	    "The subexpression ~S contains more than one  multiple-tags" expr)
    (let ((lamclause (list 'lambda (list 'z) (subst 'z (car tags-used) expr))))
      (list 'some lamclause (car tags-used)))))


(defun head (n l) 
  (subseq l 0 n))
  
;; ============================================================================
;; STRING PROCESSING
;; ============================================================================

(defun location (s) 
;; Entfernt cgi-parameter aus url. 
;;; Beispiel:
  ;;  (tab (cnt 100 (location (rxheader "referer")) 
  ;;	    (where (equal (rxheader "host") "social.dw.de") (live))))"
  
  (cl-ppcre:regex-replace "\\?.*" s ""))


(defun dissect (pattern string)
  (multiple-value-bind (total parts)
    (cl-ppcre:scan-to-strings pattern string)
    (declare (ignore total))
    parts))

(defun is-prefix (prefix string) 
  (and (>= (length string) (length prefix)) 
       (string= (subseq string 0 (length prefix)) 
		prefix)))

(defun contains (string pattern)
  "match eines Strings auf einen anderen"
  (cl-ppcre:scan pattern string))

(defun matches (pattern string)
  "match eines Strings auf einen anderen"
  (cl-ppcre:scan pattern string))

(defun substr (s from &optional to)
  (let ((l (length s)))
    (if to
	(let ((cfrom (min l from))
	      (cto (min l to)))
	  (subseq s cfrom cto))
	(let ((cfrom (min l from)))
	  (subseq s cfrom)))))

(defun numb (pattern string)
  (cl-ppcre:register-groups-bind (n) (pattern string)
    (aif n (parse-integer n))))

(defun parse-integer-or-double (str)
  (read-from-string 
   (concatenate 'string str 
		(if (position (code-char 46) str) "D0" ""))))

(defun nth-num (n string &optional (default 0))
  "Liefere n-ten match als integer" 
  (let ((res (cl-ppcre:all-matches-as-strings "([\\d\.]+)" string)))
    (if (and res (> (length res) n))
;;	(read-from-string (elt res n))
	(parse-integer-or-double (elt res n))
	default)))

;; ============================================================================ 
;; OUTPUT
;; ============================================================================ 

(defun print-log-line (l)  
      (format t "~{~5d ~14a ~a ~a~%~}" l))

(defun dump (source)
  "lisp dump"
    (loop for r = (funcall source) until (eq 'eof r) 
       do (format t "~A~%----------------------------------------~%" r) ))

(defun dmp (source)
  "lisp dump"
    (loop for r = (funcall source) until (eq 'eof r) 
       do (loop for l in r do (print-log-line l) finally (terpri))))

;;(nth-num 2 (fourth (find 'reqend (car (take 1 (file-starting-at "c:/Temp/webcache02-live.varnish.log-20150309" (epoch 0 54 8 9 3 2015 -1)))) :key #'cadr)))

(defun org-dmp (source &optional (stars "**"))
  "lisp dump"
    (loop for r = (funcall source) until (eq 'eof r)
          as n from 1
          for time = (time-string (truncate (nth-num 2 (fourth (find 'reqend r :key #'cadr)))))
       do (progn 
            (format t "~A ~A ~A~%" stars n time)
            (loop for l in r do (print-log-line l) finally (terpri)))))


(defun bulk (source)
    (loop for r = (funcall source) until (eq 'eof r) do (print r) ))

(defun col-widths-of-table (table)
  (apply #'mapcar (lambda (&rest args) (apply #'max args)) 
     (mapcar (lambda (y) 
            (mapcar (lambda (x) (length (format nil "~a" x)))
               y))
         table)))

(defun tab (table)
  "tabellarische ausgabe einer liste aus listen mit optimieren
spaltenbreiten"
  (format t
	  (concatenate 'string
		       "~{~{~&"
		       (apply #'concatenate 'string 
			      (mapcar (lambda (col) (concatenate 'string "~" (write-to-string (+ 1 col)) "a")) 
			       (butlast (col-widths-of-table table))))
		       "~a~}~}")
	  table))

;; (defun first-n (n seq)
;;   "liefert die ersten n Elemente einer Liste, egal, ob sie kürzer ist" 
;;   (subseq seq 0 (min (length seq) n)))

(defmacro chart (n chartmax expr source)
  "erstelle ein Chart über n Requests über den Wert von expr und berücksichtige nur chartmax Spitzenreiter" 
  (let ((nn (gensym)) 
	(cmax (gensym)) 
	(seq (gensym)))
    `(tab 
      (let ((,nn ,n)
	    (,cmax ,chartmax))
	(let ((,seq (cnt ,nn ,expr ,source)))
	  (subseq ,seq 0 (min (length ,seq) ,cmax)))))))

(defun tabcar (l) 
 "wie tab, arbeitet aber mit dem car der sublisten.  Beispiel:
 (tabcar (take 5 (select-tags '(rxurl) (where (and 
 (type-is 'c) (equal (rxheader \"host\") \"thebobs.com\"))  
 (live)))))"
 (tab (mapcar (lambda (x) (car x)) l)))

(defvar *unix-epoch-difference* (encode-universal-time 0 0 0 1 1 1970 0))

;; =============================================================================
;; TIME CONVERSIONS
;; =============================================================================

(defun epoch (second minute hour date month year &optional time-zone)
  (- (encode-universal-time second minute hour date month year time-zone)
     *unix-epoch-difference*))

(defun now()  
  "aktuelle Zeit als Unix-Epoche"
  (- (get-universal-time) *unix-epoch-difference*))

(defun time-string (time)
  (let ((time-zone 0))
    (multiple-value-bind (s m h day month year) 
	(decode-universal-time (+ *unix-epoch-difference* time) time-zone) 
      (format nil "~4d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d" year month day h m s))))

;; =============================================================================
;; BAN-LIST (obsolete)
;; =============================================================================

(defun ban-list ()
  "liefert die ban-list des caches als lisp-liste"
  (let ((stream (sb-ext:process-output
		 (sb-ext:run-program "varnishadm" '("ban.list")
				     :wait   nil
				     :search t 
				     :output :stream
				     :external-format '(:utf-8 :replacement #\?)
				     ))))
    (loop 
       for line = (read-line stream nil 'eof)
       for nr from 0
       until (or (eq line 'eof) (string= line ""))
       when (> nr 0)
       collect 
	 (let ((ban (cl-ppcre:split "\\s+" line)))
	   (cons (time-string (parse-integer (car ban) :junk-allowed t)) ban)))))

;; =============================================================================
;; DW-Spezifika
;; =============================================================================

(defun cms-url-type (url) 
  "bestimme eine Art URL-Typ aus einem CMS-URL. Bsp: (chart 1000
  10 (cms-url-type txurl) (where (and (type-is 'b)
  txurl (not (rxheader \"Cache-Control\"))) (live)))"
  (aif (cl-ppcre:register-groups-bind (type)  ("/(\\w\\w?-)\\d+" url) type)
       it 
       (apply #'concatenate 
	      'string (first-n (cl-ppcre:all-matches-as-strings "/[^/]+" url) 2))))

;;; Beispiel:

;;; (chart 1000 10 (cms-url-type txurl) (where (and (type-is 'b) txurl (not (rxheader "Cache-Control"))) (live)))

;;; Bestimmt ein Chart über die URL-Typen, die keinen Cache-Control-Eintrag, aber txurl haben und backend-requests sind.

(defparameter *dw-de-startpages* 
  "s-(10250|11646|11929|10037|10257|9058|9747|10261|9077|10507|11603|11546|11588|10339|11722|9993|11394|7111|13918|10575|9119|10682|30648|10201|9874|11933)" 
  "Regex zur Identifikation von Startseiten")


(defparameter *articles* "/a-\\d+")
(defparameter *av-content* "/av-\\d+")
(defparameter *structure** "/s-\\d+")

(defun ctype (str) (cl-ppcre:register-groups-bind (type) ("/(\\w{1,2}-)\\d+" str) type))

(defun ctype (str) (if (matches "/teaser/" str) "teaser" 
		       (if (matches "/images/" str) "images" 
			   (if (matches "/flashes/" str) "flashes" 
			       (if (matches "/binarydataservice/" str) "binarydataservice"
				   (aif (cl-ppcre:register-groups-bind (type) ("/(\\w{1,2}-)\\d+" str) type) it 
					str))))))

;;(defun thebobs (source) 
;;;  (where (matches "thebobs.com$" (rxheader "host")) source))

;; ============================================================================
;; EXAMPLES
;; ============================================================================

;; (defun startpages-with-cache-misses () 
;;   (dmp (select-tags '(RxUrl ReqEnd) 
;; 		     (where (and (type-is 'C) 
;; 				 (contains RxUrl *startpages*) 
;; 				 (some-line  (and (eq tag  'VCL_CALL) 
;; 						  (contains data  "miss"))))
;; 			    (live)))))

;; (defun startpages-with-cache-misses () 
;;   (dump (select-tags '(RxUrl ReqEnd) 
;; 		     (where (and (type-is 'C) 
;; 				 (contains RxUrl *startpages*) 
;; 				 (some (for line (and (eq (tag line) 'VCL_CALL) 
;; 						      (contains (data line)  "miss"))) 
;; 				       request)) 
;; 			    (live)))))

;; 'eof

;;(dump (select (or (eq tag 'TxURL) (and (eq tag 'RxHeader) (contains data "^Cache-Control: max-age="))) (where (type-is 'B) (live))))

;; (app (lambda (r) (loop for r in *c-time* do (format t "~A~10T~A~%" (max-age r) (txurl r)))) (where (type-is 'B) (live)))

;; dateninhalt von request-end aller cache-misses von startseiten

;; (defmacro any-match (tag pattern)
;;   `(some (for line (and (eq (tag line) ,tag) (matches ,pattern (data line)))))) 

;; (defun duration-of-startpages-with-cache-misses () 
;;   (take 100 (app (find-tag-data 'reqend request)
;; 	       (select-tags '(RxUrl ReqEnd) 
;; 			    (where (and (type-is 'C)
;; 					(matches *startpages* RxUrl)
;; 					;;				      (any-match 'vcl_call "miss")
;; 					(some (for line (and (eq (tag line) 'VCL_CALL) 
;; 							     (matches "miss" (data line)))) 
;; 					      request))
;; 				   (live))))))

;; (defun reqbar-to-diff (s)
;;   (apply #'- (map 'list 
;; 		  (lambda (x) 
;; 		    (with-input-from-string 
;; 			(in (concatenate 'string x "D0"))  
;; 		      (read in)))
;; 		  (subseq (cl-ppcre:split " " s) 1 3 ))))
;; Example:
;; "Dump Requests where max-age>600"
;; (dump (where (some-line (aif (numb "max-age=(\\d+)" data) (> it 600))) (testfile)))


;; ============================================================================
;; STATISTIK
;; ============================================================================

;; (defun hash-key (alist taglist)
;;   "erstelle eine Liste der Werte von a-list, deren namen in taglist stehen" 
;;   (mapcar (lambda (tag) (cdr (assoc tag alist))) taglist))


;; (defun cnt (taglist source &key (name 'count))
;;   (let ((htab (make-hash-table :test #'equal ))
;; 	(result)
;; 	(filled))
;;     (lambda ()
;;       (unless filled
;; 	(loop 
;; 	      for alist = (funcall source) until (eq alist 'eof) 
;; 	        do (inc-hash (hash-key alist taglist) htab))
;; 	(maphash (lambda (key value)
;; 		      (push (cons (cons name value) (pairlis taglist key)) result))
;; 		  htab)
;; 	(setq filled t))
;;       (if result
;; 	    (prog1 (car result)
;; 	          (setf result (cdr result)))
;; 	      'eof))))


;; ;;(defcount-expr (expr source)
;; ;;  (loop for r = (funcall source) until (eq 'eof r) do (print r) ))


;; =============================================================================

;; (defmacro cnt (n expr source)
;;   (let ((src (gensym)))
;;     `(let ((,src ,source)
;; 	   (nn ,n)
;; 	   (htab (make-hash-table :test #'equal )))
;; 	 (loop
;; 	    for request = (funcall ,src)
;; 	    for i from 1 to nn 
;; 	    until (eq 'eof request) do
;; 	      (inc-hash ,expr htab)
;; 	    finally (return (let ((res nil)) 
;; 			      (maphash (lambda (k v) (push (list k v) res)) 
;; 				       htab)
;; 			      (sort res #'> :key #'cadr)))))))

;; (defun iterator-1 (s); Zeilen-Iterator eines Streams erstellen.  Wegen
;; 		   ; Unzulänglichkeiten bei der Behandlung
;; "stream->(->request)"
;;   (lambda ()
;;     (restart-case
;; 	(handler-bind ((type-error 
;; 			#'(lambda (c)
;; 			    (declare (ignore c))
;; 			    (invoke-restart 'ignore-utf8-error #\?))))
;; 	  (read-line s nil 'eof))
;;       (ignore-utf8-error (&optional v) 
;; 	v))))


;; (defmacro ? (varname expr)
;; "poor mans lambda"
;;   `(lambda (,varname) ,expr))

;; (defmacro for (varname expr)
;; "poor mans lambda"
;;   `(lambda (,varname) ,expr))

;; (defmacro select (expr source)
;; "wähle die Zeilen eines Requests aus, die einer Bedingung genügen:
;; zB (dump (select (eq tag 'hash (live))). Zeigt Zeilen, deren Tag 'Hash
;; heisst. Belegt dabei die Variablen tag, code und data. Dient der
;; Auswahl der Zeilen eines requests."
;;   (let ((src (gensym)))
;;     `(let ((,src ,source))
;;        (lambda ()
;; 	 (let ((request (funcall ,src)))
;; 	   (if (eq 'eof request)
;; 	       'eof
;; 	   (loop for line in request
;; 	      when line
;; 	      when (let ((tag (tag line)) 
;; 			 (code (code line))
;; 			 (data (data line)))
;; 		     (declare (ignore tag code data))
;; 		     ,expr)
;; 	      collect line)))))))
