(ns sk.fixture.core)

(defn fixture-add
  "Return left plus right."
  [left right]
  (+ left right))

(defn fixture-double
  "Return twice value."
  [value]
  (fixture-add value value))

(defn fixture-answer
  "Return the fixture answer."
  []
  (fixture-double 21))

(defn -main
  [& _arguments]
  (println (fixture-answer)))
