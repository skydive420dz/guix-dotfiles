(define-module (guix-disk-health)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 format)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (main
            sk:command-result-kind
            sk:command-result-stdout
            sk:disk-health-run
            sk:make-command-result
            sk:make-subprocess-runner
            sk:privacy-safe?))

(define %program "guix-disk-health")
(define %schema "sk-guix-disk-health/v1")
(define %busctl "/run/current-system/profile/bin/busctl")
(define %service "org.freedesktop.UDisks2")
(define %block-path "/org/freedesktop/UDisks2/block_devices/sda")
(define %properties-interface "org.freedesktop.DBus.Properties")
(define %block-interface "org.freedesktop.UDisks2.Block")
(define %ata-interface "org.freedesktop.UDisks2.Drive.Ata")
(define %stale-after-seconds 1200)
(define %property-output-limit 4096)
(define %attribute-output-limit (* 128 1024))

;; Name, D-Bus signature, and internal key.  This is the complete property
;; allowlist; no CLI or environment value can extend it.
(define %property-specs
  '(("SmartSupported" "b" smart-supported)
    ("SmartEnabled" "b" smart-enabled)
    ("SmartUpdated" "t" smart-updated)
    ("SmartFailing" "b" smart-failing)
    ("SmartPowerOnSeconds" "t" smart-power-on-seconds)
    ("SmartTemperature" "d" smart-temperature)
    ("SmartNumAttributesFailing" "i" smart-num-failing)
    ("SmartNumAttributesFailedInThePast" "i" smart-num-failed-past)
    ("SmartNumBadSectors" "x" smart-num-bad-sectors)
    ("SmartSelftestStatus" "s" smart-selftest-status)
    ("SmartSelftestPercentRemaining" "i" smart-selftest-remaining)))

;; Name, required pretty-unit value, and whether a nonzero pretty value is a
;; failing indicator.  Unit 1 is dimensionless and unit 3 is sectors.
(define %selected-attribute-specs
  '(("reallocated-sector-count" 3 #t)
    ("used-reserved-blocks-total" 1 #t)
    ("program-fail-count-total" 1 #t)
    ("erase-fail-count-total" 1 #t)
    ("runtime-bad-block-total" 1 #t)
    ("reported-uncorrect" 3 #t)
    ("hardware-ecc-recovered" 1 #f)
    ("udma-crc-error-count" 1 #t)
    ("power-cycle-count" 1 #f)
    ("wear-leveling-count" 1 #f)))

(define-record-type <command-result>
  (sk:make-command-result kind stdout)
  command-result?
  (kind sk:command-result-kind)
  (stdout sk:command-result-stdout))

(define-record-type <render-result>
  (make-render-result destination text exit-code)
  render-result?
  (destination render-result-destination)
  (text render-result-text)
  (exit-code render-result-exit-code))

(define (raise-health code)
  (throw 'sk-disk-health code))

(define (protocol-assert condition)
  (unless condition
    (raise-health 'protocol-invalid)))

(define (alist-value object key)
  (let ((entry (and (list? object) (assoc key object))))
    (and entry (cdr entry))))

(define (object-with-exact-keys? object expected)
  (and (list? object)
       (= (length object) (length expected))
       (every (lambda (entry)
                (and (pair? entry) (string? (car entry))))
              object)
       (every (lambda (key)
                (= 1 (count (lambda (entry)
                              (string=? key (car entry)))
                            object)))
              expected)))

(define (integer-between? value minimum maximum)
  (and (integer? value) (<= minimum value maximum)))

(define (finite-number? value)
  (and (real? value)
       (= value value)
       (< (abs value) 1.0e308)))

(define (dbus-value-valid? signature value)
  (cond
   ((string=? signature "b") (boolean? value))
   ((string=? signature "t")
    (integer-between? value 0 18446744073709551615))
   ((string=? signature "d") (finite-number? value))
   ((string=? signature "i")
    (integer-between? value -2147483648 2147483647))
   ((string=? signature "x")
    (integer-between? value -9223372036854775808 9223372036854775807))
   ((string=? signature "s")
    (and (string? value)
         (<= (string-length value) 128)
         (not (string-index value #\nul))))
   ((string=? signature "o")
    (and (string? value)
         (<= 1 (string-length value) 1024)
         (char=? (string-ref value 0) #\/)
         (not (string-index value #\nul))))
   (else #f)))

(define (parse-json payload)
  (protocol-assert (string? payload))
  (catch #t
    (lambda ()
      (json-string->scm payload #:ordered #t))
    (lambda (key . arguments)
      (if (eq? key 'quit)
          (apply throw key arguments)
          (raise-health 'protocol-invalid)))))

(define (parse-property payload expected-signature)
  (let* ((outer (parse-json payload))
         (outer-data (alist-value outer "data")))
    (protocol-assert (object-with-exact-keys? outer '("type" "data")))
    (protocol-assert (and (string? (alist-value outer "type"))
                          (string=? (alist-value outer "type") "v")))
    (protocol-assert (and (vector? outer-data)
                          (= (vector-length outer-data) 1)))
    (let ((variant (vector-ref outer-data 0)))
      (protocol-assert
       (object-with-exact-keys? variant '("type" "data")))
      (protocol-assert
       (and (string? (alist-value variant "type"))
            (string=? (alist-value variant "type") expected-signature)))
      (let ((value (alist-value variant "data")))
        (protocol-assert (dbus-value-valid? expected-signature value))
        value))))

(define (ascii-object-character? character)
  (let ((code (char->integer character)))
    (or (<= (char->integer #\A) code (char->integer #\Z))
        (<= (char->integer #\a) code (char->integer #\z))
        (<= (char->integer #\0) code (char->integer #\9))
        (char=? character #\_))))

(define (private-drive-path? value)
  (let* ((prefix (string-append "/org/freedesktop/UDisks2/" "drives/"))
         (prefix-length (string-length prefix)))
    (and (string? value)
         (string-prefix? prefix value)
         (> (string-length value) prefix-length)
         (every ascii-object-character?
                (string->list (substring value prefix-length))))))

(define (selected-attribute-spec name)
  (find (lambda (spec) (string=? name (car spec)))
        %selected-attribute-specs))

(define (unit-label unit)
  (case unit
    ((1) "count")
    ((2) "milliseconds")
    ((3) "sectors")
    ((4) "millikelvin")
    (else "unknown")))

(define (parse-attribute-tuple tuple)
  (protocol-assert (and (vector? tuple) (= (vector-length tuple) 9)))
  (let ((id (vector-ref tuple 0))
        (name (vector-ref tuple 1))
        (flags (vector-ref tuple 2))
        (value (vector-ref tuple 3))
        (worst (vector-ref tuple 4))
        (threshold (vector-ref tuple 5))
        (pretty (vector-ref tuple 6))
        (unit (vector-ref tuple 7))
        (expansion (vector-ref tuple 8)))
    (protocol-assert (integer-between? id 0 255))
    (protocol-assert (and (string? name)
                          (<= 1 (string-length name) 128)
                          (not (string-index name #\nul))))
    (protocol-assert (integer-between? flags 0 65535))
    (for-each (lambda (normalized)
                (protocol-assert
                 (or (integer-between? normalized 0 255)
                     (and (integer? normalized)
                          (= normalized -1)))))
              (list value worst threshold))
    (protocol-assert
     (integer-between? pretty -9223372036854775808 9223372036854775807))
    (protocol-assert (integer-between? unit -2147483648 2147483647))
    ;; UDisks 2.10.1 documents this dictionary as unused.  Reject future
    ;; expansion data until its privacy and meaning are reviewed.
    (protocol-assert (null? expansion))
    (let ((spec (selected-attribute-spec name)))
      (and spec
           (begin
             (protocol-assert (= unit (cadr spec)))
             (protocol-assert (>= pretty 0))
             `((name . ,name)
               (pretty . ,pretty)
               (unit . ,unit)
               (normalized . ,value)
               (failing-indicator? . ,(caddr spec))))))))

(define (parse-attributes payload)
  (let* ((outer (parse-json payload))
         (data (alist-value outer "data")))
    (protocol-assert (object-with-exact-keys? outer '("type" "data")))
    (protocol-assert
     (and (string? (alist-value outer "type"))
          (string=? (alist-value outer "type") "a(ysqiiixia{sv})")))
    (protocol-assert (and (vector? data) (= (vector-length data) 1)))
    (let ((tuples (vector-ref data 0))
          (selected '()))
      (protocol-assert (vector? tuples))
      (let loop ((index 0))
        (when (< index (vector-length tuples))
          (let ((attribute
                 (parse-attribute-tuple (vector-ref tuples index))))
            (when attribute
              (let ((name (assq-ref attribute 'name)))
                (protocol-assert (not (assoc name selected)))
                (set! selected (acons name attribute selected)))))
          (loop (+ index 1))))
      (let ((ordered
             (map (lambda (spec)
                    (let ((entry (assoc (car spec) selected)))
                      (protocol-assert entry)
                      (cdr entry)))
                  %selected-attribute-specs)))
        (list->vector ordered)))))

(define (busctl-prefix activation-policy)
  (list "--system"
        "--json=short"
        "--no-pager"
        "--expect-reply=yes"
        (if (eq? activation-policy 'cached-only)
            "--auto-start=no"
            "--auto-start=yes")
        "--allow-interactive-authorization=no"
        "--timeout=5s"
        "call"))

(define (block-drive-command activation-policy)
  (append
   (busctl-prefix activation-policy)
   (list %service
         %block-path
         %properties-interface
         "Get"
         "ss"
         %block-interface
         "Drive")))

(define (ata-property-command activation-policy private-path property-name)
  (append
   (busctl-prefix activation-policy)
   (list %service
         private-path
         %properties-interface
         "Get"
         "ss"
         %ata-interface
         property-name)))

(define (attribute-command activation-policy private-path)
  (append
   (busctl-prefix activation-policy)
   (list %service
         private-path
         %ata-interface
         "SmartGetAttributes"
         "a{sv}"
         "0")))

(define (wait-status-kind status)
  (catch #t
    (lambda ()
      (let ((normal (status:exit-val status)))
        (cond ((and (integer? normal) (zero? normal)) 'ok)
              ;; child-exec reserves 127 for setup or execl failure.
              ((and (integer? normal) (= normal 127)) 'runner-error)
              ((integer? normal) 'child-exit)
              ((status:term-sig status) 'signal)
              (else 'runner-error))))
    (lambda _ 'runner-error)))

(define (close-quietly port)
  (catch #t
    (lambda () (close-port port))
    (lambda _ #f)))

(define (monotonic-now)
  (get-internal-real-time))

(define (seconds->ticks seconds)
  (* seconds internal-time-units-per-second))

(define (deadline-remaining deadline)
  (max 0 (- deadline (monotonic-now))))

(define (ticks->select-time ticks)
  (let ((seconds (quotient ticks internal-time-units-per-second))
        (remainder (remainder ticks internal-time-units-per-second)))
    (values seconds
            (quotient (* remainder 1000000)
                      internal-time-units-per-second))))

(define (waitpid-retry pid options)
  (catch 'system-error
    (lambda () (waitpid pid options))
    (lambda arguments
      (if (= (system-error-errno arguments) EINTR)
          (waitpid-retry pid options)
          (apply throw arguments)))))

(define (wait-quietly pid)
  (catch #t
    (lambda () (cdr (waitpid-retry pid 0)))
    (lambda _ #f)))

(define (terminate-and-reap pid)
  (catch #t
    (lambda () (kill pid SIGKILL))
    (lambda _ #f))
  (wait-quietly pid))

(define (child-exec program arguments read-port write-port)
  (catch #t
    (lambda ()
      (close-port read-port)
      (dup2 (port->fdes write-port) 1)
      (close-port write-port)
      (let ((null-fd (open-fdes "/dev/null" O_RDWR)))
        (dup2 null-fd 0)
        (dup2 null-fd 2)
        (close-fdes null-fd))
      (setenv "LC_ALL" "C")
      (for-each unsetenv
                '("DBUS_SYSTEM_BUS_ADDRESS"
                  "DBUS_SESSION_BUS_ADDRESS"
                  "SYSTEMD_PAGER"
                  "PAGER"
                  "SYSTEMD_COLORS"
                  "NO_COLOR"))
      (apply execl program program arguments))
    (lambda _
      (primitive-exit 127))))

(define (wait-for-child pid deadline mark-reaped!)
  (let loop ()
    (let ((result (waitpid-retry pid WNOHANG)))
      (if (zero? (car result))
          (let ((remaining (deadline-remaining deadline)))
            (if (zero? remaining)
                #f
                (call-with-values
                    (lambda ()
                      (ticks->select-time
                       (min remaining
                            (quotient internal-time-units-per-second 100))))
                  (lambda (seconds microseconds)
                    (select '() '() '() seconds microseconds)
                    (loop)))))
          (begin
            (mark-reaped!)
            (cdr result))))))

(define (read-child pid read-port deadline maximum-bytes mark-reaped!)
  (call-with-values open-bytevector-output-port
    (lambda (sink extract)
      (let loop ((total 0))
        (let ((remaining (deadline-remaining deadline)))
          (if (zero? remaining)
              (sk:make-command-result 'timeout "")
              (call-with-values
                  (lambda () (ticks->select-time remaining))
                (lambda (seconds microseconds)
                  (let* ((ready
                          (select (list read-port) '() '()
                                  seconds microseconds))
                         (readable (car ready)))
                    (if (null? readable)
                        (sk:make-command-result 'timeout "")
                        (let ((chunk (get-bytevector-some read-port)))
                          (if (eof-object? chunk)
                              (let ((status
                                     (wait-for-child pid deadline
                                                     mark-reaped!)))
                                (if status
                                    (let ((kind (wait-status-kind status)))
                                      (if (eq? kind 'ok)
                                          (catch #t
                                            (lambda ()
                                              (sk:make-command-result
                                               'ok
                                               (utf8->string (extract))))
                                            (lambda _
                                              (sk:make-command-result
                                               'invalid-utf8 "")))
                                          ;; Discard stdout for every child
                                          ;; failure or signal termination.
                                          (sk:make-command-result kind "")))
                                    (sk:make-command-result 'timeout "")))
                              (let ((new-total
                                     (+ total (bytevector-length chunk))))
                                (if (> new-total maximum-bytes)
                                    (sk:make-command-result 'oversize "")
                                    (begin
                                      (put-bytevector sink chunk)
                                      (loop new-total))))))))))))))))

(define* (sk:make-subprocess-runner program #:optional (timeout-seconds 7))
  (lambda (arguments maximum-bytes)
    (catch #t
      (lambda ()
        (let ((read-port #f)
              (write-port #f)
              (pid #f)
              (reaped? #f))
          (dynamic-wind
            (lambda () #t)
            (lambda ()
              (let ((ports (pipe)))
                (set! read-port (car ports))
                (set! write-port (cdr ports)))
              (set! pid (primitive-fork))
              (if (zero? pid)
                  (child-exec program arguments read-port write-port)
                  (begin
                    (close-quietly write-port)
                    (set! write-port #f)
                    (let ((deadline (+ (monotonic-now)
                                       (seconds->ticks timeout-seconds))))
                      (read-child pid read-port deadline maximum-bytes
                                  (lambda () (set! reaped? #t)))))))
            (lambda ()
              (when read-port (close-quietly read-port))
              (when write-port (close-quietly write-port))
              (when (and pid (> pid 0) (not reaped?))
                (terminate-and-reap pid))))))
      (lambda (key . arguments)
        (if (eq? key 'quit)
            (apply throw key arguments)
            (sk:make-command-result 'runner-error ""))))))

(define (invoke runner arguments maximum-bytes activation-policy)
  (let ((result
         (catch #t
           (lambda () (runner arguments maximum-bytes))
           (lambda (key . exception-arguments)
             (if (eq? key 'quit)
                 (apply throw key exception-arguments)
                 (raise-health 'transport-failed))))))
    (unless (command-result? result)
      (raise-health 'transport-failed))
    (case (sk:command-result-kind result)
      ((oversize invalid-utf8 protocol-invalid)
       (raise-health 'protocol-invalid))
      ((child-exit)
       (raise-health (if (eq? activation-policy 'cached-only)
                         'source-unavailable
                         'transport-failed)))
      ((ok)
       (let ((payload (sk:command-result-stdout result)))
         (unless (and (string? payload)
                      (<= (bytevector-length (string->utf8 payload))
                          maximum-bytes))
           (raise-health 'protocol-invalid))
         payload))
      (else (raise-health 'transport-failed)))))

(define (property-ref properties key)
  (let ((entry (assq key properties)))
    (protocol-assert entry)
    (cdr entry)))

(define (normalize-selftest value)
  (cond
   ((string=? value "success") '("success-or-never" neutral))
   ((string=? value "aborted") '("aborted" unknown))
   ((string=? value "interrupted") '("interrupted" unknown))
   ((string=? value "inprogress") '("in-progress" unknown))
   ((or (string=? value "fatal")
        (member value '("error_unknown"
                        "error_electrical"
                        "error_servo"
                        "error_read"
                        "error_handling")))
    '("failure-indicator" failing))
   (else '("unknown" unknown))))

(define (validate-summary properties)
  (let ((updated (property-ref properties 'smart-updated))
        (temperature (property-ref properties 'smart-temperature))
        (power-on (property-ref properties 'smart-power-on-seconds))
        (num-failing (property-ref properties 'smart-num-failing))
        (num-past (property-ref properties 'smart-num-failed-past))
        (bad-sectors (property-ref properties 'smart-num-bad-sectors))
        (remaining (property-ref properties 'smart-selftest-remaining)))
    (when (zero? updated)
      (raise-health 'source-unavailable))
    (protocol-assert (or (zero? temperature)
                         (and (> temperature 0) (< temperature 1000))))
    (protocol-assert (>= power-on 0))
    (for-each (lambda (counter)
                (protocol-assert (or (= counter -1) (>= counter 0))))
              (list num-failing num-past bad-sectors))
    (protocol-assert (or (= remaining -1)
                         (integer-between? remaining 0 100)))))

(define (attribute-ref attribute key)
  (assq-ref attribute key))

(define (attribute-failure? attribute)
  (and (attribute-ref attribute 'failing-indicator?)
       (> (attribute-ref attribute 'pretty) 0)))

(define (attribute-unknown? attribute)
  (= (attribute-ref attribute 'normalized) -1))

(define (classify properties attributes cache-state selftest-class)
  (let ((failing?
         (or (property-ref properties 'smart-failing)
             (> (property-ref properties 'smart-num-failing) 0)
             (> (property-ref properties 'smart-num-failed-past) 0)
             (> (property-ref properties 'smart-num-bad-sectors) 0)
             (eq? selftest-class 'failing)
             (any attribute-failure? (vector->list attributes))))
        (unknown?
         (or (not (eq? cache-state 'fresh))
             (not (property-ref properties 'smart-supported))
             (not (property-ref properties 'smart-enabled))
             (zero? (property-ref properties 'smart-temperature))
             (zero? (property-ref properties 'smart-power-on-seconds))
             (= (property-ref properties 'smart-num-failing) -1)
             (= (property-ref properties 'smart-num-failed-past) -1)
             (= (property-ref properties 'smart-num-bad-sectors) -1)
             (= (property-ref properties 'smart-selftest-remaining) -1)
             (eq? selftest-class 'unknown)
             (any attribute-unknown? (vector->list attributes)))))
    (cond (failing? 'failing-indicator)
          (unknown? 'unknown)
          (else 'favorable))))

(define (cache-state age)
  (cond ((< age 0) 'future)
        ((> age %stale-after-seconds) 'stale)
        (else 'fresh)))

(define (collect-observation runner activation-policy now)
  (let* ((private-path
          (parse-property
           (invoke runner
                   (block-drive-command activation-policy)
                   %property-output-limit
                   activation-policy)
           "o")))
    (protocol-assert (private-drive-path? private-path))
    (let ((properties
           (map (lambda (spec)
                  (let ((name (car spec))
                        (signature (cadr spec))
                        (key (caddr spec)))
                    (cons key
                          (parse-property
                           (invoke runner
                                   (ata-property-command
                                    activation-policy private-path name)
                                   %property-output-limit
                                   activation-policy)
                           signature))))
                %property-specs)))
      (validate-summary properties)
      (let* ((attributes
              (parse-attributes
               (invoke runner
                       (attribute-command activation-policy private-path)
                       %attribute-output-limit
                       activation-policy)))
             (updated (property-ref properties 'smart-updated))
             (age (- now updated))
             (state (cache-state age))
             (selftest
              (normalize-selftest
               (property-ref properties 'smart-selftest-status)))
             (classification
              (classify properties attributes state (cadr selftest))))
        `((classification . ,classification)
          (activation-policy . ,activation-policy)
          (cache-updated . ,updated)
          (cache-age . ,age)
          (cache-state . ,state)
          (selftest-display . ,(car selftest))
          (properties . ,properties)
          (attributes . ,attributes))))))

(define (nullable-counter value)
  (if (= value -1) 'null value))

(define (nullable-positive value)
  (if (zero? value) 'null value))

(define (observation-ref observation key)
  (assq-ref observation key))

(define (attribute-json attribute)
  `(("name" . ,(attribute-ref attribute 'name))
    ("value" . ,(attribute-ref attribute 'pretty))
    ("unit" . ,(unit-label (attribute-ref attribute 'unit)))
    ("normalized" . ,(if (= (attribute-ref attribute 'normalized) -1)
                           'null
                           (attribute-ref attribute 'normalized)))))

(define (observation-json observation summary?)
  (let* ((properties (observation-ref observation 'properties))
         (temperature (property-ref properties 'smart-temperature))
         (power-on (property-ref properties 'smart-power-on-seconds))
         (base
          `(("schema" . ,%schema)
            ("status" . "observed")
            ("classification" . ,(symbol->string
                                    (observation-ref observation
                                                     'classification)))
            ("activation_policy" . ,(symbol->string
                                      (observation-ref observation
                                                       'activation-policy)))
            ("view" . ,(if summary? "summary" "full"))
            ("cache" . (("updated_epoch" . ,(observation-ref
                                               observation 'cache-updated))
                        ("age_seconds" . ,(observation-ref
                                            observation 'cache-age))
                        ("state" . ,(symbol->string
                                     (observation-ref observation
                                                      'cache-state)))
                        ("stale_after_seconds" . ,%stale-after-seconds)))
            ("smart" . (("supported" . ,(property-ref
                                           properties 'smart-supported))
                        ("enabled" . ,(property-ref
                                        properties 'smart-enabled))
                        ("drive_failing" . ,(property-ref
                                              properties 'smart-failing))
                        ("temperature_c" . ,(if (zero? temperature)
                                                 'null
                                                 (- temperature 273.15)))
                        ("power_on_seconds" . ,(nullable-positive power-on))
                        ("power_on_hours" . ,(if (zero? power-on)
                                                  'null
                                                  (quotient power-on 3600)))
                        ("current_failing_attributes" .
                         ,(nullable-counter
                           (property-ref properties 'smart-num-failing)))
                        ("attributes_failed_in_past" .
                         ,(nullable-counter
                           (property-ref properties 'smart-num-failed-past)))
                        ("bad_sectors" .
                         ,(nullable-counter
                           (property-ref properties 'smart-num-bad-sectors)))
                        ("self_test_status" . ,(observation-ref
                                                 observation
                                                 'selftest-display))
                        ("self_test_percent_remaining" .
                         ,(nullable-counter
                           (property-ref
                            properties 'smart-selftest-remaining))))))))
    (if summary?
        base
        (append base
                `(("attributes" .
                   ,(list->vector
                     (map attribute-json
                          (vector->list
                           (observation-ref observation 'attributes))))))))))

(define (human-counter value suffix)
  (if (= value -1)
      "unknown"
      (format #f "~a~a" value suffix)))

(define (render-human observation summary?)
  (let* ((properties (observation-ref observation 'properties))
         (temperature (property-ref properties 'smart-temperature))
         (power-on (property-ref properties 'smart-power-on-seconds)))
    (call-with-output-string
      (lambda (port)
        (format port "~a~%" %program)
        (format port "status: observed~%")
        (format port "classification: ~a~%"
                (symbol->string
                 (observation-ref observation 'classification)))
        (format port "activation policy: ~a~%"
                (symbol->string
                 (observation-ref observation 'activation-policy)))
        (format port "view: ~a~%" (if summary? "summary" "full"))
        (format port "cache: ~a (age ~a s; updated epoch ~a; stale after ~a s)~%"
                (symbol->string (observation-ref observation 'cache-state))
                (observation-ref observation 'cache-age)
                (observation-ref observation 'cache-updated)
                %stale-after-seconds)
        (format port "SMART supported: ~a~%"
                (if (property-ref properties 'smart-supported) "yes" "no"))
        (format port "SMART enabled: ~a~%"
                (if (property-ref properties 'smart-enabled) "yes" "no"))
        (format port "drive failing indicator: ~a~%"
                (if (property-ref properties 'smart-failing) "yes" "no"))
        (format port "temperature: ~a~%"
                (if (zero? temperature)
                    "unknown"
                    (format #f "~,2f C" (- temperature 273.15))))
        (format port "power-on time: ~a~%"
                (if (zero? power-on)
                    "unknown"
                    (format #f "~a h (~a s)" (quotient power-on 3600) power-on)))
        (format port "current failing attributes: ~a~%"
                (human-counter
                 (property-ref properties 'smart-num-failing) ""))
        (format port "attributes failed in past: ~a~%"
                (human-counter
                 (property-ref properties 'smart-num-failed-past) ""))
        (format port "bad sectors: ~a~%"
                (human-counter
                 (property-ref properties 'smart-num-bad-sectors) ""))
        (format port "self-test: ~a (remaining ~a)~%"
                (observation-ref observation 'selftest-display)
                (human-counter
                 (property-ref properties 'smart-selftest-remaining) "%"))
        (unless summary?
          (format port "selected cached attributes:~%")
          (let ((attributes (observation-ref observation 'attributes)))
            (let loop ((index 0))
              (when (< index (vector-length attributes))
                (let ((attribute (vector-ref attributes index)))
                  (format port "  ~a: ~a ~a; normalized ~a~%"
                          (attribute-ref attribute 'name)
                          (attribute-ref attribute 'pretty)
                          (unit-label (attribute-ref attribute 'unit))
                          (if (= (attribute-ref attribute 'normalized) -1)
                              "unknown"
                              (attribute-ref attribute 'normalized))))
                (loop (+ index 1))))))))))

(define %mac-pattern
  (make-regexp "(^|[^0-9A-Fa-f])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f]|$)"))
(define %uuid-pattern
  (make-regexp "(^|[^0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}([^0-9A-Fa-f]|$)"))

(define (sk:privacy-safe? rendered)
  (let ((lower (string-downcase rendered))
        (private-prefix (string-append "/org/freedesktop/UDisks2/" "drives/")))
    (and (not (regexp-exec %mac-pattern rendered))
         (not (regexp-exec %uuid-pattern rendered))
         (every (lambda (fragment) (not (string-contains lower fragment)))
                (list (string-downcase private-prefix)
                      "/dev/"
                      "/by-id/"
                      "serial"
                      "wwn"
                      "partuuid"
                      "\"uuid\""
                      "\"model\"")))))

(define (render-observation observation json? summary?)
  (let ((rendered
         (if json?
             (string-append
              (scm->json-string (observation-json observation summary?))
              "\n")
             (render-human observation summary?))))
    (unless (sk:privacy-safe? rendered)
      (raise-health 'privacy-violation))
    rendered))

(define %usage
  (string-append
   "usage: guix-disk-health [--json] [--summary] "
   "[--allow-activate|--cached-only]\n"
   "\n"
   "Read allowlisted cached ATA SMART state through UDisks.\n"
   "  --allow-activate  permit normal D-Bus activation (default)\n"
   "  --cached-only     prohibit D-Bus service auto-start\n"
   "  --summary         omit detailed attribute rendering\n"
   "  --json            emit the versioned JSON schema\n"
   "  --help            show this help without contacting D-Bus\n"))

(define (parse-options arguments)
  (let loop ((rest arguments)
             (json? #f)
             (summary? #f)
             (activation-policy #f)
             (help? #f)
             (seen '()))
    (if (null? rest)
        `((json? . ,json?)
          (summary? . ,summary?)
          (activation-policy . ,(or activation-policy 'allow))
          (help? . ,help?))
        (let ((argument (car rest)))
          (when (or (not (string? argument))
                    (member argument seen))
            (throw 'sk-usage))
          (cond
           ((string=? argument "--json")
            (loop (cdr rest) #t summary? activation-policy help?
                  (cons argument seen)))
           ((string=? argument "--summary")
            (loop (cdr rest) json? #t activation-policy help?
                  (cons argument seen)))
           ((string=? argument "--cached-only")
            (when activation-policy (throw 'sk-usage))
            (loop (cdr rest) json? summary? 'cached-only help?
                  (cons argument seen)))
           ((string=? argument "--allow-activate")
            (when activation-policy (throw 'sk-usage))
            (loop (cdr rest) json? summary? 'allow help?
                  (cons argument seen)))
           ((string=? argument "--help")
            (loop (cdr rest) json? summary? activation-policy #t
                  (cons argument seen)))
           (else (throw 'sk-usage)))))))

(define (error-code->exit code)
  (case code
    ((protocol-invalid privacy-violation) 65)
    ((source-unavailable) 69)
    ((internal-invariant) 70)
    ((transport-failed) 74)
    (else 70)))

(define (error-render-result options code)
  (let* ((json? (assq-ref options 'json?))
         (unavailable? (eq? code 'source-unavailable))
         (code-string (symbol->string code))
         (rendered
          (if json?
              (string-append
               (scm->json-string
                `(("schema" . ,%schema)
                  ("status" . ,(if unavailable? "unavailable" "error"))
                  ("error" . ,code-string)))
               "\n")
              (format #f "~a: ~a: ~a~%"
                      %program
                      (if unavailable? "unavailable" "error")
                      code-string))))
    (make-render-result (if json? 'output 'error)
                        rendered
                        (error-code->exit code))))

(define (usage-render-result)
  (make-render-result 'error %usage 64))

(define (compute-render-result arguments runner now)
  (catch 'sk-usage
    (lambda ()
      (let ((options (parse-options arguments)))
        (if (assq-ref options 'help?)
            (begin
              (when (> (length arguments) 1)
                (throw 'sk-usage))
              (make-render-result 'output %usage 0))
            (catch #t
              (lambda ()
                (catch 'sk-disk-health
                  (lambda ()
                    (let* ((observation
                            (collect-observation
                             runner
                             (assq-ref options 'activation-policy)
                             now))
                           (rendered
                            (render-observation
                             observation
                             (assq-ref options 'json?)
                             (assq-ref options 'summary?))))
                      (make-render-result 'output rendered 0)))
                  (lambda (_key code)
                    (error-render-result options code))))
              (lambda (key . exception-arguments)
                (if (eq? key 'quit)
                    (apply throw key exception-arguments)
                    (error-render-result options
                                         'internal-invariant)))))))
    (lambda _ (usage-render-result))))

(define (sk:disk-health-run arguments runner now output-port error-port)
  (let ((result (compute-render-result arguments runner now)))
    ;; This is the only write performed by the command.  A port failure is
    ;; allowed to propagate; it is never retried as a second error render.
    (display (render-result-text result)
             (if (eq? (render-result-destination result) 'output)
                 output-port
                 error-port))
    (render-result-exit-code result)))

(define (main arguments)
  (exit
   (sk:disk-health-run
    (cdr arguments)
    (sk:make-subprocess-runner %busctl 7)
    (current-time)
    (current-output-port)
    (current-error-port))))
