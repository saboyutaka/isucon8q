#!/bin/bash

wget https://github.com/KLab/myprofiler/releases/download/0.1/myprofiler.linux_amd64.tar.gz
tar xf myprofiler.linux_amd64.tar.gz
sudo mv myprofiler /usr/local/bin/
rm myprofiler.linux_amd64.tar.gz
