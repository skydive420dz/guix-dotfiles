#!/usr/bin/env -S guile --no-auto-compile -s
!#

(use-modules (ice-9 match)
             (srfi srfi-1)
             (srfi srfi-13))

(define repo
  (dirname (dirname (canonicalize-path (car (command-line))))))
(primitive-load (string-append repo "/scripts/sk-network"))

(define checks 0)
(define failures 0)

(define (check condition label)
  (set! checks (+ checks 1))
  (unless condition
    (set! failures (+ failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define wifi-uuid "aaaaaaaa-1111-4222-8333-aaaaaaaaaaaa")
(define wired-uuid "bbbbbbbb-1111-4222-8333-bbbbbbbbbbbb")

(define calls '())

(define (query-tail arguments fields)
  (and
   (>= (length arguments) 7)
   (equal? (take arguments 7)
           (list "--colors" "no" "--terse" "--escape" "yes"
                 "--fields" fields))
   (drop arguments 7)))

(define (fake-runner program arguments seconds)
  (set! calls (cons (list (basename program) arguments seconds) calls))
  (cond
   ((equal? (query-tail arguments "RUNNING,STATE,CONNECTIVITY")
            '("general"))
    (command-result 'ok "running:connected:full\n"))
   ((equal? (query-tail arguments "WIFI-HW,WIFI") '("radio"))
    (command-result 'ok "enabled:enabled\n"))
   ((equal? (query-tail arguments "DEVICE,TYPE,STATE,CONNECTION")
            '("device" "status"))
    (command-result
     'ok
     (string-append
      "wlp4s0:wifi:connected:Home\\:Net\n"
      "enp2s0:ethernet:unavailable:--\n"
      "lo:loopback:connected (externally):lo\n")))
   ((equal? (query-tail arguments "NAME,UUID,TYPE,DEVICE")
            '("connection" "show"))
    (command-result
     'ok
     (string-append
      "Home\\:Net:" wifi-uuid ":802-11-wireless:wlp4s0\n"
      "Office\\\\Lab:" wired-uuid ":802-3-ethernet:--\n"
      "lo:cccccccc-1111-4222-8333-cccccccccccc:loopback:lo\n")))
   ((equal? (query-tail arguments "IN-USE,SSID,SIGNAL,SECURITY")
            '("device" "wifi" "list" "--rescan" "no"))
    (command-result
     'ok
     (string-append
      "*:Home\\:Net:73:WPA2\n"
      ":Cafe\\\\Guest:52:--\n")))
   ((member arguments
            (list
             '("--wait" "15" "device" "wifi" "rescan")
             '("--wait" "15" "radio" "wifi" "on")
             '("--wait" "15" "radio" "wifi" "off")
             (list "--wait" "20" "connection" "up" "uuid" wired-uuid)
             (list "--wait" "20" "connection" "down" "uuid" wifi-uuid)))
    (command-result 'ok ""))
   (else (command-result 'failed ""))))

(set! sk:network-command-runner fake-runner)

(check-equal (split-row "Home\\:Net:Office\\\\Lab" 2 "fixture")
             '("Home:Net" "Office\\Lab")
             "escaped separators and backslashes decode")
(check
 (catch 'sk-network-error
   (lambda () (split-row "trailing\\" 1 "fixture") #f)
   (lambda _ #t))
 "trailing escape fails closed")

(define snapshot (build-snapshot))
(check-equal (field (cdr (assq 'manager (cdr snapshot))) 'running)
             'yes "manager state parses")
(check-equal (field (cdr (assq 'wifi (cdr snapshot))) 'radio)
             'enabled "Wi-Fi radio parses")
(check-equal
 (field (car (cdr (assq 'devices (cdr snapshot)))) 'connection)
 "Home:Net" "device connection name decodes")

(define connections (cdr (assq 'connections (cdr snapshot))))
(check-equal (length connections) 2 "loopback profile is excluded")
(check-equal (field (cadr connections) 'name)
             "Office\\Lab" "saved connection name decodes")

(define access-points (cdr (assq 'access-points (cdr snapshot))))
(check-equal (field (car access-points) 'ssid)
             "Home:Net" "SSID decodes")
(check-equal (field (cadr access-points) 'security)
             "open" "open network normalizes")

(define (called? arguments)
  (any (lambda (call) (equal? (cadr call) arguments)) calls))

(define forbidden '("PASSWORD" "BSSID" "MAC" "--show-secrets"))
(check
 (every
  (lambda (argument)
    (not (any (lambda (word) (string-contains argument word))
              forbidden)))
  (append-map cadr calls))
 "snapshot requests no secrets or hardware identifiers")

(set! calls '())
(scan)
(check (called? '("--wait" "15" "device" "wifi" "rescan"))
       "scan uses bounded nmcli rescan")

(set! calls '())
(set-wifi #f)
(check (called? '("--wait" "15" "radio" "wifi" "off"))
       "Wi-Fi off uses nmcli radio")

(set! calls '())
(connect wired-uuid)
(check
 (called?
  (list "--wait" "20" "connection" "up" "uuid" wired-uuid))
 "connect uses a validated saved UUID")

(set! calls '())
(disconnect wifi-uuid)
(check
 (called?
  (list "--wait" "20" "connection" "down" "uuid" wifi-uuid))
 "disconnect requires an active saved UUID")

(set! calls '())
(check
 (catch 'sk-network-error
   (lambda () (disconnect wired-uuid) #f)
   (lambda _ #t))
 "inactive connection cannot be disconnected")
(check
 (not
  (called?
   (list "--wait" "20" "connection" "down" "uuid" wired-uuid)))
 "rejected disconnect performs no action")

(set! calls '())
(check
 (catch 'sk-network-error
   (lambda () (connect "bad;touch") #f)
   (lambda _ #t))
 "injected connection identifier fails closed")
(check
 (not (any (lambda (call) (member "up" (cadr call))) calls))
 "rejected identifier performs no connect action")

(check (> checks 15) "focused suite executed")

(if (zero? failures)
    (begin
      (format #t "sk-network checks: ~a passed~%" checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "sk-network checks: ~a failure(s) of ~a~%"
              failures checks)
      (exit 1)))
