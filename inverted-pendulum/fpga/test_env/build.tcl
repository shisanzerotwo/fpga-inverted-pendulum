# 环境验收构建脚本：gw_sh.exe build.tcl
create_project -name test_env -force -dir . -pn GW2A-LV18PG256C8/I7 -device_version C
add_file D:/GitHub/xiangmu/FPGA/inverted-pendulum/fpga/test_env/src/counter.v
add_file D:/GitHub/xiangmu/FPGA/inverted-pendulum/fpga/test_env/constraint/test_env.cst
set_option -top_module top
# led[4]=T10、led[1]=C10 位于 SSPI 专用脚，必须开启专用脚作 GPIO
set_option -use_sspi_as_gpio 1
run syn
run pnr
