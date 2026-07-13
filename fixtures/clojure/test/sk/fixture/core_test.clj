(ns sk.fixture.core-test
  (:require [clojure.test :refer [deftest is testing]]
            [sk.fixture.core :as fixture]))

(deftest fixture-arithmetic-test
  (testing "the dependency-free fixture returns 42"
    (is (= 42 (fixture/fixture-add 20 22)))
    (is (= 42 (fixture/fixture-double 21)))
    (is (= 42 (fixture/fixture-answer)))))
