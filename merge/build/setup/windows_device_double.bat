echo "setup for Windows Device Double (GTX 2800)"

set DOUBLEDEFINE=-DPRJACUDADOUBLE


set DOUBLEFLAGS=%DOUBLEDEFINE% -arch=sm_13


set PRJACUDACFLAGS=-I include/common %DOUBLEFLAGS%
set BLA="set by skript"
set PRJACUDAOBJEXT=obj
set PRJACUDAEXEEXT=exe

set PRJACUDAHOSTLD=link
set PRJACUDALIBEXT=lib
set PRJACUDAHOSCC=cl
