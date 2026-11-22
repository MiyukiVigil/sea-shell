#!/usr/bin/env python3
"""Minimal zwlr_virtual_pointer_v1 client over the raw wire protocol. Commands on argv:
   move:X:Y  down  up  click  rclick  sleep:S"""
import os,socket,struct,sys,time
W,H=1300,900
s=socket.socket(socket.AF_UNIX);s.connect(os.path.join(os.environ['XDG_RUNTIME_DIR'],os.environ['WAYLAND_DISPLAY']))
def send(obj,op,payload=b''):s.sendall(struct.pack('<IHH',obj,op,8+len(payload))+payload)
def st(t):
    b=t.encode()+b'\0';return struct.pack('<I',len(b))+b+b'\0'*((4-len(b)%4)%4)
send(1,1,struct.pack('<I',2))           # get_registry -> 2
send(1,0,struct.pack('<I',3))           # sync -> 3
buf=b'';mgr=None;done=False
while not done:
    buf+=s.recv(65536)
    while len(buf)>=8:
        o,oe=struct.unpack('<II',buf[:8]);sz=oe>>16;op=oe&0xffff
        if len(buf)<sz:break
        body=buf[8:sz];buf=buf[sz:]
        if o==2 and op==0:
            n,l=struct.unpack('<II',body[:8]);nm=body[8:8+l-1].decode()
            if nm=='zwlr_virtual_pointer_manager_v1':mgr=n
        if o==3:done=True
assert mgr,'no virtual pointer manager'
send(2,0,struct.pack('<I',mgr)+st('zwlr_virtual_pointer_manager_v1')+struct.pack('<II',1,4))
send(4,0,struct.pack('<II',0,5))        # create_virtual_pointer(seat=null) -> 5
t=lambda:int(time.time()*1000)&0x7fffffff
def frame():send(5,4)
def move(x,y):send(5,1,struct.pack('<IIIII',t(),x,y,W,H));frame()
def btn(state):send(5,2,struct.pack('<III',t(),0x110,state));frame()
for c in sys.argv[1:]:
    if c.startswith('move:'):
        _,x,y=c.split(':');move(int(x),int(y))
    elif c=='down':btn(1)
    elif c=='up':btn(0)
    elif c=='click':btn(1);time.sleep(.05);btn(0)
    elif c=='rclick':
        send(5,2,struct.pack('<III',t(),0x111,1));frame();time.sleep(.05)
        send(5,2,struct.pack('<III',t(),0x111,0));frame()
    elif c.startswith('sleep:'):time.sleep(float(c[6:]))
    time.sleep(.03)
time.sleep(.1)
