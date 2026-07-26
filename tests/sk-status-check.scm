(use-modules (ice-9 ftw)
             (ice-9 textual-ports)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 3)
  (error "usage: sk-status-check.scm REPOSITORY TEMP-DIRECTORY"))

(define repo (list-ref arguments 1))
(define tmp (list-ref arguments 2))
(primitive-load (string-append repo "/scripts/sk-status"))

(define checks 0)
(define failures 0)

(define (check condition label)
  (set! checks (+ checks 1))
  (unless condition
    (set! failures (+ failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define target-a (string-append tmp "/store-a-system"))
(define target-b (string-append tmp "/store-b-system"))
(define generation (string-append tmp "/system-87-link"))
(define profile (string-append tmp "/system"))
(define active (string-append tmp "/active"))
(define booted (string-append tmp "/booted"))

(mkdir target-a)
(mkdir target-b)
(symlink target-a generation)
(symlink generation profile)
(symlink target-a active)
(symlink target-a booted)

(check-equal (generation-number profile "system") 87
             "generation number parses")
(check-equal (field (observe-generation profile active booted) 'state)
             'unknown
             "generation targets outside the accepted store root are rejected")
(check-equal
 (observe-generation profile active booted (string-append tmp "/"))
 '((state ok) (current 87) (active-current yes) (booted-current yes))
 "matching generation links are healthy")

(delete-file booted)
(symlink target-b booted)
(check-equal
 (observe-generation profile active booted (string-append tmp "/"))
 '((state ok) (current 87) (active-current yes) (booted-current no))
 "boot mismatch is represented without changing the links")

(delete-file active)
(symlink target-b active)
(check-equal
 (field (observe-generation profile active booted (string-append tmp "/"))
        'state)
 'degraded
 "active generation mismatch is degraded")

(check-equal (read-one-form "(500 \"30.2\" yes 5)")
             '(500 "30.2" yes 5)
             "single cross-reader form parses")
(check (not (read-one-form "(ok) (extra)"))
       "trailing form is rejected")

(define healthy-runner
  (lambda (program command-arguments)
    (let ((name (basename program)))
      (cond
       ((string=? name "emacsclient")
        (command-result 'ok "(500 \"30.2\" yes 5)\n"))
       ((string=? name "herd")
        (command-result 'ok "Status:\n  It is running.\n"))
       ((or (string=? name "dbus-send")
            (string=? name "wpctl"))
        (command-result 'ok ""))
       ((and (string=? name "bluetoothctl")
             (equal? command-arguments '("show")))
        (command-result
         'ok
         "Controller 00:11:22:33:44:55 Private Adapter\n\tPowered: yes\n"))
       ((string=? name "bluetoothctl")
        (command-result
         'ok
         "Device AA:BB:CC:DD:EE:FF Private Speaker\n"))
       ((string=? name "nmcli")
        (command-result 'ok "running:connected:full\n"))
       ((string=? name "df")
        (command-result 'ok "Use%       Avail\n 46% 41316802560\n"))
       ((string=? name "guix-disk-health")
        (command-result 'ok "classification: favorable\n"))
       (else (command-result 'unavailable ""))))))

(set! sk:command-runner healthy-runner)

(define desktop (observe-desktop))
(define session (observe-session))
(define audio (observe-audio))
(define bluetooth (observe-bluetooth))
(define network (observe-network))
(define capacity (observe-capacity))
(define smart (observe-smart))
(define healthy-storage
  `((capacity ,@capacity)
    (smart ,@smart)
    (trim (state ok) (schedule sunday-1800) (filesystems ext4))))

(check-equal (field (section desktop 'exwm) 'workspaces) 5
             "EXWM workspace count is normalized")
(check-equal (field (section session 'dbus) 'state) 'ok
             "D-Bus result is normalized")
(check-equal (field (section audio 'pipewire) 'state) 'ok
             "PipeWire result is normalized")
(check-equal bluetooth
             '((state ok) (controller powered) (connected-devices 1))
             "Bluetooth identifiers are reduced to state and count")
(check-equal network
             '((state ok) (manager running)
               (connection connected) (connectivity full))
             "Network identifiers are absent from normalized state")
(check-equal (parse-root-capacity "Use% Avail\n 75% 26843545600\n")
             '(75 26843545600)
             "capacity parser accepts the fixed df shape")
(check-equal (field capacity 'state) 'ok
             "root capacity below both thresholds is healthy")
(check-equal smart
             '((state ok) (classification favorable))
             "existing SMART summary is normalized")

(let ((rendered
       (call-with-output-string
         (lambda (port)
           (write (list 'bluetooth bluetooth) port)))))
  (check (not (string-contains rendered "00:11:22"))
         "controller address is not emitted")
  (check (not (string-contains rendered "Private"))
         "device names are not emitted"))

(define healthy-generations
  `((system (state ok) (current 87)
            (active-current yes) (booted-current yes))
    (home (state ok) (current 52) (active-current yes))
    (pull (state ok) (current 5) (active-current yes))))

(check-equal
 (snapshot-findings healthy-generations desktop session audio
                    bluetooth network healthy-storage)
 '()
 "healthy fixture has no findings")

(define degraded-network
  '((state degraded) (manager running)
    (connection connected) (connectivity limited)))
(let ((findings
       (snapshot-findings healthy-generations desktop session audio
                          bluetooth degraded-network healthy-storage)))
  (check-equal (overall-status findings) 'degraded
               "warning finding degrades overall status")
  (check-equal (field (car findings) 'code)
               'network-connectivity-degraded
               "network warning uses stable code"))

(define constrained-storage
  '((capacity (state degraded) (used-percent 75) (available-gib 25))
    (smart (state ok) (classification favorable))
    (trim (state ok) (schedule sunday-1800) (filesystems ext4))))
(let ((findings
       (snapshot-findings healthy-generations desktop session audio
                          bluetooth network constrained-storage)))
  (check-equal (field (car findings) 'code)
               'root-capacity-threshold
               "accepted capacity threshold emits recovery guidance"))

(check (> checks 10) "focused suite executed")

(if (zero? failures)
    (begin
      (format #t "sk-status Scheme checks: ~a passed~%" checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "sk-status Scheme checks: ~a failure(s) of ~a~%"
              failures checks)
      (exit 1)))
