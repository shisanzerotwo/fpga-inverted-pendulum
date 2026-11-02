# gw_build.tcl -- full command-line build (syn -> pnr -> bitstream).
# Usage, from anywhere:   gw_sh.exe _tools/gw_build.tcl
# Output:                 fpga_project/impl/pnr/fpga_project.fs
#
# 2026-10-05 portability fix: the previous version hard-coded
#   C:/Users/Xie/Desktop/verilog/fpga_project/fpga_project.gprj
# which only exists on the machine the project was authored on -- on any other
# clone the script died with OPEN_ERROR.  The project file is now resolved
# relative to this script, so one command works everywhere.
# The .gprj stays the single source of truth for the file list (add new RTL
# there, not here).
set here [file dirname [file normalize [info script]]]
set gprj [file normalize [file join $here .. fpga_project fpga_project.gprj]]

puts "===== OPEN PROJECT ====="
puts "gprj: $gprj"
if {[catch {open_project $gprj} err]} {
    puts "OPEN_ERROR: $err"
    exit 1
}
puts "OPEN_OK"

puts "===== RUN ALL ====="
if {[catch {run all} err]} {
    puts "RUN_ERROR: $err"
    exit 1
}
puts "===== BUILD END ====="
exit
