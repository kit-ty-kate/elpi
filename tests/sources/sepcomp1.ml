let us = [{|

main :- p.

|}; {|

p :- print "ok".

|}; ]
;;

let () = Sepcomp.Sepcomp_template.main us;;