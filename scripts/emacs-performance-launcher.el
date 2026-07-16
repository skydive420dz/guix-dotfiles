;;; emacs-performance-launcher.el --- Pre-Ivy launcher timing -*- lexical-binding: t; -*-

;; This payload measures the existing already-loaded preparation path.  It must
;; not call Ivy, launch a process, register an intent, or mutate ambient caches.

(progn
  (unless (and (featurep 'counsel)
               (featurep 'exwm)
               (fboundp 'sk/exwm-supported-desktop-entry-p))
    (error "already-loaded launcher preparation functions are unavailable"))
  (let ((initial-cache-populated
         (if counsel--linux-apps-cache "true" "false"))
        (initial-cached-files-count
         (length counsel--linux-apps-cached-files))
        (counsel--linux-apps-cache
         (copy-tree counsel--linux-apps-cache))
        (counsel--linux-apps-cached-files
         (copy-sequence counsel--linux-apps-cached-files))
        (counsel--linux-apps-cache-timestamp
         counsel--linux-apps-cache-timestamp)
        (counsel--linux-apps-cache-format-function
         counsel--linux-apps-cache-format-function)
        (counsel-linux-apps-faulty
         (copy-sequence counsel-linux-apps-faulty))
        (inhibit-message t)
        (message-log-max nil)
        samples)
    (dotimes (index 5)
      (let* ((buffers-before (length (buffer-list)))
             (frames-before (length (frame-list)))
             (processes-before (length (process-list)))
             (intents-before (length sk/exwm-launch-intents))
             (threshold-before gc-cons-threshold)
             (percentage-before gc-cons-percentage)
             (gcs-before gcs-done)
             (gc-elapsed-before gc-elapsed)
             (started (current-time))
             (desktop-files (counsel-linux-apps-list-desktop-files))
             (all-candidates (counsel-linux-apps-list))
             (supported
              (seq-filter
               (lambda (candidate)
                 (sk/exwm-supported-desktop-entry-p candidate desktop-files))
               all-candidates))
             (elapsed-ms
              (* 1000.0
                 (float-time (time-subtract (current-time) started))))
             (gc-count-delta (- gcs-done gcs-before))
             (gc-elapsed-ms
              (* 1000.0 (- gc-elapsed gc-elapsed-before))))
        (push
         `((index . ,(1+ index))
           (elapsed_ms . ,elapsed-ms)
           (desktop_files . ,(length desktop-files))
           (all_candidates . ,(length all-candidates))
           (supported_candidates . ,(length supported))
           (gc_count_delta . ,gc-count-delta)
           (gc_elapsed_ms . ,gc-elapsed-ms)
           (buffer_delta . ,(- (length (buffer-list)) buffers-before))
           (frame_delta . ,(- (length (frame-list)) frames-before))
           (process_delta . ,(- (length (process-list)) processes-before))
           (intent_delta
            . ,(- (length sk/exwm-launch-intents) intents-before))
           (gc_cons_threshold_before . ,threshold-before)
           (gc_cons_threshold_after . ,gc-cons-threshold)
           (gc_cons_percentage_before . ,percentage-before)
           (gc_cons_percentage_after . ,gc-cons-percentage))
         samples)))
    (json-serialize
     `((protocol . "sk-emacs-performance-launcher-v1")
       (timer . "emacs-current-time")
       (cache_mode . "already-loaded-natural-cache")
       (initial_cache_populated . ,initial-cache-populated)
       (initial_cached_files_count . ,initial-cached-files-count)
       (samples . ,(vconcat (nreverse samples)))))))
