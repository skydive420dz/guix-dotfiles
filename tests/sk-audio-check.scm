(use-modules (ice-9 match)
             (srfi srfi-1))

(define arguments (command-line))
(unless (= (length arguments) 2)
  (error "usage: sk-audio-check.scm REPOSITORY"))

(define repo (list-ref arguments 1))
(primitive-load (string-append repo "/scripts/sk-audio"))

(define checks 0)
(define failures 0)

(define (check condition label)
  (set! checks (+ checks 1))
  (unless condition
    (set! failures (+ failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define calls '())

(define list-output
  (string-append
   "49\talsa_card.test\taudio/device\t \n"
   "57\talsa_output.hdmi\taudio/sink\t \n"
   "71\tbluez_output.test\taudio/sink\t*\n"
   "60\talsa_input.test\taudio/source\t \n"))

(define status-output
  (string-append
   "Audio\n"
   " └─ Streams:\n"
   "        88. Chromium\n"
   "             89. output_FL > Test Speaker:playback_FL [active]\n"
   "\n"
   "Video\n"
   " └─ Streams:\n"))

(define (inspect-output id)
  (cond
   ((string=? id "57")
    "  * node.description = \"HDMI Output\"\n")
   ((string=? id "71")
    "  * node.description = \"Bose Mini II SoundLink\"\n")
   ((string=? id "60")
    "  * node.description = \"Test Microphone\"\n")
   ((string=? id "88")
    (string-append
     "    media.name = \"Playback\"\n"
     "  * node.name = \"Chromium\"\n"))
   (else "")))

(define (volume-output id)
  (cond
   ((string=? id "57") "Volume: 0.80\n")
   ((string=? id "71") "Volume: 0.45\n")
   ((string=? id "60") "Volume: 0.30\n")
   ((string=? id "88") "Volume: 0.75 [MUTED]\n")
   (else "")))

(define (fake-runner program command-arguments seconds)
  (set! calls
        (cons (list (basename program) command-arguments seconds) calls))
  (match command-arguments
    (("list" "audio") (command-result 'ok list-output))
    (("status" "--name") (command-result 'ok status-output))
    (("inspect" id) (command-result 'ok (inspect-output id)))
    (("get-volume" id) (command-result 'ok (volume-output id)))
    ((or ("set-default" _)
         ("set-volume" _ _)
         ("set-volume" "-l" "1.0" "@DEFAULT_AUDIO_SINK@" "5%+")
         ("set-mute" _ "toggle"))
     (command-result 'ok ""))
    (_ (command-result 'failed ""))))

(set! sk:audio-command-runner fake-runner)

(check-equal (parse-natural "71") 71 "numeric object id parses")
(check (not (parse-natural "71;touch")) "injected object id is rejected")
(check-equal (parse-percent "100") 100 "maximum volume parses")
(check (not (parse-percent "101")) "oversized volume is rejected")

(define objects (listed-objects))
(check-equal (length objects) 4 "device rows are excluded")
(check-equal (field (find (lambda (record)
                            (= (field record 'id) 71))
                          objects)
                    'default)
             'yes
             "default sink marker parses")
(check-equal (field (find (lambda (record)
                            (= (field record 'id) 88))
                          objects)
                    'kind)
             'stream
             "stream comes from the Audio status tree")

(define snapshot (build-snapshot))
(define records (cdr (assq 'objects (cdr snapshot))))
(define bose (find (lambda (record)
                     (= (field record 'id) 71))
                   records))
(define chromium (find (lambda (record)
                         (= (field record 'id) 88))
                       records))
(check-equal (field bose 'description) "Bose Mini II SoundLink"
             "sink description comes from inspect")
(check-equal (field bose 'volume) 45 "sink volume normalizes to percent")
(check-equal (field chromium 'description) "Chromium"
             "stream node name wins over generic media name")
(check-equal (field chromium 'muted) 'yes "stream mute state parses")

(define (called? arguments)
  (any (lambda (call) (equal? (cadr call) arguments)) calls))

(set! calls '())
(set-default "57")
(check (called? '("set-default" "57")) "default endpoint uses wpctl")

(set! calls '())
(set-volume "88" "33")
(check (called? '("set-volume" "88" "33%"))
       "exact stream volume uses a validated percent")

(set! calls '())
(check
 (catch 'sk-audio-error
   (lambda ()
     (set-volume "88" "101")
     #f)
   (lambda _ #t))
 "oversized action volume fails closed")
(check (not (any (lambda (call)
                   (member "set-volume" (cadr call)))
                 calls))
       "rejected volume performs no volume action")

(set! calls '())
(check
 (catch 'sk-audio-error
   (lambda ()
     (set-default "88")
     #f)
   (lambda _ #t))
 "stream cannot become a default endpoint")

(set! calls '())
(toggle-mute "88")
(check (called? '("set-mute" "88" "toggle"))
       "stream mute uses wpctl")

(set! calls '())
(step-volume 'up)
(check (called?
        '("set-volume" "-l" "1.0" "@DEFAULT_AUDIO_SINK@" "5%+"))
       "volume up keeps the existing 100 percent cap")

(set! calls '())
(step-volume 'down)
(check (called?
        '("set-volume" "@DEFAULT_AUDIO_SINK@" "5%-"))
       "volume down targets the default sink")

(set! calls '())
(check
 (catch 'sk-audio-error
   (lambda ()
     (toggle-mute "88;touch")
     #f)
   (lambda _ #t))
 "injected action id fails closed")
(check (not (any (lambda (call)
                   (member "set-mute" (cadr call)))
                 calls))
       "rejected id performs no mute action")

(set! sk:audio-command-runner
      (lambda (_program command-arguments _seconds)
        (if (equal? command-arguments '("list" "audio"))
            (command-result 'ok "malformed\n")
            (command-result 'failed ""))))
(check
 (catch 'sk-audio-error
   (lambda ()
     (listed-objects)
     #f)
   (lambda _ #t))
 "malformed list output fails closed")

(set! sk:audio-command-runner
      (lambda (_program command-arguments _seconds)
        (cond
         ((equal? command-arguments '("list" "audio"))
          (command-result 'ok list-output))
         ((equal? command-arguments '("status" "--name"))
          (command-result 'ok "Audio\nVideo\n"))
         (else (command-result 'failed "")))))
(check
 (catch 'sk-audio-error
   (lambda ()
     (listed-objects)
     #f)
   (lambda _ #t))
 "missing audio streams section fails closed")

(check (> checks 15) "focused suite executed")

(if (zero? failures)
    (begin
      (format #t "sk-audio Scheme checks: ~a passed~%" checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "sk-audio Scheme checks: ~a failure(s) of ~a~%"
              failures checks)
      (exit 1)))
