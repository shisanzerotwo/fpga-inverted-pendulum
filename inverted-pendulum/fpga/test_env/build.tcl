# 环境验收构建脚本。任意目录运行：gw_sh.exe <本文件路径>
# 路径相对本脚本所在目录解析，工程产物输出到本脚本目录下的 test_env/
set here [file dirname [file normalize [info script]]]
create_project -name test_env -force -dir $here -pn GW2A-LV18PG256C8/I7 -device_version C
add_file $here/src/counter.v
add_file $here/constraint/test_env.cst
set_option -top_module top
# led[4]=T10、led[1]=C10 位于 SSPI 专用脚，必须开启专用脚作 GPIO
set_option -use_sspi_as_gpio 1
run syn
run pnr
