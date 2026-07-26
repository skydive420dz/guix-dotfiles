(use-modules (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 2)
  (error "usage: sk-bluetooth-check.scm REPOSITORY"))

(define repo (list-ref arguments 1))
(primitive-load (string-append repo "/scripts/sk-bluetooth"))

(define checks 0)
(define failures 0)

(define (check condition label)
  (set! checks (+ checks 1))
  (unless condition
    (set! failures (+ failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define adapter "/org/bluez/hci0")
(define speaker
  "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")
(define keyboard
  "/org/bluez/hci0/dev_11_22_33_44_55_66")
(define calls '())
(define adapter-powered? #t)

(define (typed signature value)
  (string-append
   (symbol->string signature) " "
   (call-with-output-string (lambda (port) (write value port)))
   "\n"))

(define (boolean-output value)
  (string-append "b " (if value "true" "false") "\n"))

(define (property-output path interface name)
  (cond
   ((and (string=? path adapter) (string=? name "Alias"))
    (typed 's "Test Adapter"))
   ((and (string=? path adapter) (string=? name "Powered"))
    (boolean-output adapter-powered?))
   ((and (string=? path adapter) (string=? name "Discovering"))
    (boolean-output #f))
   ((string=? name "Address")
    (typed 's
           (if (string=? path speaker)
               "AA:BB:CC:DD:EE:FF"
               "11:22:33:44:55:66")))
   ((string=? name "Alias")
    (typed 's
           (if (string=? path speaker) "Test Speaker" "Test Keyboard")))
   ((string=? name "Paired")
    (boolean-output (string=? path speaker)))
   ((string=? name "Trusted")
    (boolean-output (string=? path speaker)))
   ((string=? name "Connected")
    (boolean-output #f))
   ((string=? name "UUIDs")
    (if (string=? path speaker)
        (format #f "as 1 ~s~%" %audio-sink-uuid)
        "as 0\n"))
   ((and (string=? interface "org.bluez.Battery1")
         (string=? name "Percentage")
         (string=? path speaker))
    "y 77\n")
   (else "")))

(define (fake-runner program command-arguments seconds)
  (set! calls (cons (list (basename program) command-arguments seconds) calls))
  (let ((name (basename program)))
    (cond
     ((and (string=? name "busctl")
           (member "tree" command-arguments))
      (command-result
       'ok
       (string-append "/\n/org\n/org/bluez\n" adapter "\n"
                      speaker "\n" keyboard "\n")))
     ((and (string=? name "busctl")
           (member "get-property" command-arguments))
      (let* ((tail (drop command-arguments
                         (- (length command-arguments) 5)))
             (path (list-ref tail 2))
             (interface (list-ref tail 3))
             (property-name (list-ref tail 4)))
        (command-result
         'ok (property-output path interface property-name))))
     ((member name '("busctl" "bluetoothctl"))
      (command-result 'ok ""))
     (else (command-result 'unavailable "")))))

(set! sk:bluetooth-command-runner fake-runner)

(check (adapter-path? adapter) "adapter path is recognized")
(check (device-path? speaker) "device path is recognized")
(check (not (device-path? (string-append speaker "/fd0")))
       "device child path is rejected")
(check (valid-address? "aa:bb:cc:dd:ee:ff")
       "lowercase address is accepted")
(check (not (valid-address? "AA:BB:CC:DD:EE:FF;touch /tmp/no"))
       "address injection is rejected")
(check-equal (decode-property "s \"hello world\"\n") "hello world"
             "string property parses")
(check-equal (decode-property "b true\n") 'yes
             "boolean property parses")
(check-equal
 (decode-property
  (format #f "as 1 ~s~%" %audio-sink-uuid))
 (list %audio-sink-uuid)
 "string-array property parses")

(define snapshot (build-snapshot))
(define snapshot-adapter (cdr (assq 'adapter (cdr snapshot))))
(define snapshot-devices (cdr (assq 'devices (cdr snapshot))))

(check-equal (cadr (assq 'powered snapshot-adapter)) 'yes
             "snapshot reports adapter power")
(check-equal (length snapshot-devices) 2
             "snapshot lists exact device objects")
(check-equal
 (cadr (assq 'audio (find
                     (lambda (record)
                       (equal? (cadr (assq 'alias record))
                               "Test Speaker"))
                     snapshot-devices)))
 'yes
 "audio capability is normalized")
(check-equal
 (cadr (assq 'battery (find
                       (lambda (record)
                         (equal? (cadr (assq 'alias record))
                                 "Test Speaker"))
                       snapshot-devices)))
77
 "optional battery percentage is normalized")

(set! sk:bluetooth-command-runner
      (lambda _ (command-result 'unavailable "")))
(check-equal
 (cadr (assq 'state (cdr (assq 'adapter (cdr (build-snapshot))))))
 'unavailable
 "BlueZ query failure is distinct from an absent adapter")
(set! sk:bluetooth-command-runner fake-runner)

(define (called? command)
  (any (lambda (call) (member command (cadr call))) calls))

(set! calls '())
(connect "AA:BB:CC:DD:EE:FF")
(check (called? "Connect") "connect uses Device1.Connect")

(set! calls '())
(disconnect "AA:BB:CC:DD:EE:FF")
(check (not (called? "Disconnect"))
       "disconnect is a no-op for an already disconnected device")

(set! calls '())
(trust "11:22:33:44:55:66" #t)
(check (called? "Trusted") "trust writes Device1.Trusted")

(set! calls '())
(connect-audio-profile "AA:BB:CC:DD:EE:FF")
(check (and (called? "ConnectProfile")
            (called? %audio-sink-uuid))
       "audio profile uses the remote Audio Sink UUID")

(set! calls '())
(scan 3)
(check (any (lambda (call)
              (and (string=? (car call) "bluetoothctl")
                   (= (caddr call) 5)
                   (equal? (cadr call)
                           '("--timeout" "3" "scan" "on"))))
            calls)
       "scan is bounded by both client and outer timeout")

(set! calls '())
(pair "11:22:33:44:55:66")
(check (and (called? "NoInputNoOutput") (called? "pair"))
       "pair uses the bounded BlueZ agent client")

(check-equal (parse-scan-seconds "30") 30
             "maximum scan duration is accepted")
(check (not (parse-scan-seconds "31"))
       "oversized scan duration is rejected")
(check
 (catch 'sk-bluetooth-error
   (lambda ()
     (connect "AA:BB:CC:DD:EE:FF;touch")
     #f)
   (lambda _ #t))
 "action address validation fails closed")

(check (> checks 15) "focused suite executed")

(if (zero? failures)
    (begin
      (format #t "sk-bluetooth Scheme checks: ~a passed~%" checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "sk-bluetooth Scheme checks: ~a failure(s) of ~a~%"
              failures checks)
      (exit 1)))
