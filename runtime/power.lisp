;;;; Capability-honest power policy.
;;;; New upstream code (issue #2): no power-policy code exists in
;;;; starintel-server@f8e20c0b. The policy consumes caller-supplied power
;;;; state only; it never fabricates battery data. Unknown state defers by
;;;; default (fail-closed).

(in-package #:star.edge.power)

(defstruct (power-policy
             (:constructor make-power-policy
                 (&key (battery-floor 20) (unavailable-action :defer))))
  battery-floor
  unavailable-action)

(defun power-decision (policy state)
  "Decide :ALLOW or :DEFER for the caller-supplied power STATE plist.
STATE is (:source :ac|:battery|:unavailable :percent N)."
  (let ((source (getf state :source :unavailable))
        (percent (getf state :percent)))
    (cond ((eq source :ac) :allow)
          ((eq source :battery)
           (if (and (numberp percent)
                    (>= percent (power-policy-battery-floor policy)))
               :allow
               :defer))
          ((eq source :unavailable)
           (power-policy-unavailable-action policy))
          (t :defer))))
