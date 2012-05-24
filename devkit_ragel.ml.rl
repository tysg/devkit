
%%{
 machine ipv4;
 octet = digit{1,3} >{ n := 0; } ${ n := 10 * !n + (Char.code fc - Char.code '0') } ;
 main := octet %{ set () } '.' octet %{ set () } '.' octet %{ set () } '.' octet %{ set () } ;
 write data;
}%%

let parse_ipv4 data =
  let cs = ref 0 and p = ref 0 and pe = ref (String.length data) and eof = ref (String.length data) in
  let n = ref 0 in
  let ip = ref 0l in
  let set () =
    if !n > 255 then invalid_arg "parse_ipv4";
    ip := Int32.logor (Int32.shift_left !ip 8) (Int32.of_int !n)
  in
  %%write init;
  %%write exec;
  if !cs >= ipv4_first_final then !ip else invalid_arg "parse_ipv4"

let is_ipv4 data =
  let cs = ref 0 and p = ref 0 and pe = ref (String.length data) and eof = ref (String.length data) in
  let n = ref 0 in
  let set () = if !n > 255 then raise Not_found in
  %%write init;
  try
  %%write exec;
  !cs >= ipv4_first_final
  with Not_found -> false

