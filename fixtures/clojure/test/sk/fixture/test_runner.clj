(ns sk.fixture.test-runner
  (:require [clojure.test :as test]
            [sk.fixture.core-test]))

(defn -main
  [& _arguments]
  (let [result (test/run-tests 'sk.fixture.core-test)
        failures (+ (:fail result) (:error result))]
    (shutdown-agents)
    (System/exit (if (zero? failures) 0 1))))
