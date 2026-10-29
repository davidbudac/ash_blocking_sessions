function valid(t, a,y,m,d,maxd) {
 if(t=="AUTO") return 1
 if(t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return 0
 split(t,a,/[-T:]/); y=a[1]+0; m=a[2]+0; d=a[3]+0
 if(y<1 || m<1 || m>12 || a[4]+0>23 || a[5]+0>59 || a[6]+0>59) return 0
 maxd=31
 if(m==4 || m==6 || m==9 || m==11) maxd=30
 if(m==2) maxd=28+(y%4==0 && (y%100!=0 || y%400==0))
 return d>=1 && d<=maxd
}
BEGIN {
 b=ENVIRON["ASH_BEGIN_TIME"]; e=ENVIRON["ASH_END_TIME"]
 if(!valid(b) || !valid(e) || (b!="AUTO" && e!="AUTO" && b>=e)) {
 print "ERROR: times must be AUTO or valid YYYY-MM-DDTHH:MM:SS, begin before end" > "/dev/stderr"; exit 2
 }
}
