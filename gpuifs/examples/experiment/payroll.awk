# payroll.awk: validation and pay arithmetic for payroll.rc, in integer
# cents. Reads the three inputs' value files, writes each field's error file,
# and on success the pay stub, a register row and the total line.
# Prints the new state, "n gross net" (cents), for payroll.rc to keep.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function slurp(f,  s, l) { s = ""; while((getline l < f) > 0) s = s l; close(f); return s }
# hund: a number to hundredths, rounded half up; "" if it is not one
function hund(s,  neg, ip, fp, i, v) {
	if(s !~ /^[+-]?[0-9]*\.?[0-9]*$/ || s !~ /[0-9]/) return ""
	neg = substr(s, 1, 1) == "-"; sub(/^[+-]/, "", s)
	ip = s; fp = ""
	if(i = index(s, ".")) { ip = substr(s, 1, i-1); fp = substr(s, i+1) }
	fp = fp "000"
	v = (ip+0)*100 + substr(fp, 1, 2) + (substr(fp, 3, 1)+0 >= 5)
	return neg ? -v : v
}
function amount(s) {
	if(s ~ /^[+-]?\$/) sub(/\$/, "", s)
	gsub(/,/, "", s)
	return hund(s)
}
function hrs(h) { return sprintf("%d.%02d", int(h/100), h%100) }
function money(c,  s, t) {
	s = sprintf("%d", int(c/100)); t = ""
	while(length(s) > 3) { t = "," substr(s, length(s)-2) t; s = substr(s, 1, length(s)-3) }
	return "$" s t "." sprintf("%02d", c%100)
}
function put(f, s) { printf "%s", s > f; close(f) }
BEGIN {
	name = trim(slurp(F "/user/in/value"))
	hs = trim(slurp(F "/hours/in/value")); H = hund(hs)
	rs = trim(slurp(F "/rate/in/value")); R = amount(rs)
	ue = he = re = ""
	if(name == "") ue = "Who are we paying?"
	if(H == "") he = "Hours must be a number"
	else if(H > 16800 || H <= 0) he = "There are 168 hours in a week"
	if(R == "") re = "Rate must be an amount"
	else if(R > 999999 || R <= 0) re = "Rate must be 0.01 to 9,999.99"
	put(F "/user/error", ue); put(F "/hours/error", he); put(F "/rate/error", re)
	if(ue he re != "") { print N, TG, TN, "bad"; exit }

	name = substr(name, 1, 40)
	reg = H > 4000 ? 4000 : H; ot = H - reg
	rp = int((reg*R + 50) / 100)
	op = int((ot*R*3 + 100) / 200)
	g = rp + op
	fed = g <= 50000 ? int((g + 5) / 10) : 5000 + int(((g-50000)*22 + 50) / 100)
	fica = int((g*765 + 5000) / 10000)
	net = g - fed - fica

	S = B "/stub/stub/items"
	printf "Employee\t%s\n", name > S
	printf "Regular, %s h\t%s\n", hrs(reg), money(rp) > S
	printf "Overtime, %s h at 1.5\t%s\n", hrs(ot), money(op) > S
	printf "Gross pay\t%s\n", money(g) > S
	printf "Federal tax\t-%s\n", money(fed) > S
	printf "FICA, 7.65%%\t-%s\n", money(fica) > S
	printf "Net pay\t%s\n", money(net) > S
	close(S)
	if(N < 99) {
		N++; TG += g; TN += net
		put(B "/reg/table/append", sprintf("%d\t%s\t%s\t%s\t%s\n", N, name, hrs(H), money(R), money(net)))
		put(B "/reg/foot/total/text", sprintf("%d paid. Gross %s, net %s.", N, money(TG), money(TN)))
	}
	print N, TG, TN, "ok"
}
