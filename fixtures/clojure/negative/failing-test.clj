;; intentionally-failing
(ns sk.fixture.core-test
  (:require [clojure.test :refer [deftest is]]
            [sk.fixture.core :as fixture]))

(deftest negative-control-test
  (is (= 41 (fixture/fixture-answer))))
