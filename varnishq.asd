;;;; varnishq.asd

(asdf:defsystem #:varnishq
  :serial t
  :description "DSL zur schnellen Analyse von Varnish-Logfiles"
  :author "Patrick Krusenotto  <your.name@example.com>"
  :license "Specify license here"
  :depends-on (#:cl-ppcre
               #:alexandria)
  :components ((:file "package")
               (:file "varnishq")))

