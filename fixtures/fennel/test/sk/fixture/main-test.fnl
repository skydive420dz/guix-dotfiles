(local main (require :sk.fixture.main))

(assert (= 42 (main.fixture-answer)) "fixture answer differed")
(print "fennel fixture tests: PASS")
