# Strict, ordered, single-use SQL*Plus framing. Run with LC_ALL=C.
function fail(msg) { print "ERROR: invalid report protocol: " msg > "/dev/stderr"; bad=1; exit 1 }
/^__META_JSON_BEGIN__$/ { if (stage!=0) fail("unexpected META begin"); stage=1; next }
/^__META_JSON_END__$/ { if(stage!=1 || !nm) fail("unexpected/empty META end"); stage=2; next }
/^__DATA_JSON_BEGIN__$/ { if(stage!=2) fail("unexpected DATA begin"); stage=3; next }
/^__DATA_JSON_END__$/ { if(stage!=3 || !nd) fail("unexpected/empty DATA end"); stage=4; next }
/^__(META|DATA)_JSON_/ { fail("unknown marker") }
stage==1 || stage==3 {
 if (length($0)<3 || substr($0,1,1)!="#" || substr($0,length($0),1)!="#") fail("missing chunk sentinels")
 s=substr($0,2,length($0)-2)
 # UTF-8 continuation bytes do not count as characters; byte bound also
 # protects POSIX LINE_MAX. SQL JSON must not contain literal controls.
 chars=s; gsub(/[\200-\277]/,"",chars)
 if(length(s)>2000 || length(chars)>500 || s ~ /[[:cntrl:]]/) fail("invalid chunk size/control character")
 if(stage==1) {print s > mf; nm++} else {print s > df; nd++}
 next
}
/^[[:space:]]*(ORA-|SP2-|TNS-)/ { fail("SQL*Plus error despite successful exit") }
/^#/ { fail("chunk outside payload") }
{ print "    " $0 }
END { if(!bad && stage!=4) {print "ERROR: incomplete report protocol" > "/dev/stderr"; exit 1} }
