!# /bin/bash

sudo yum update -y
sudo yum -y install \
    vim \
    git \
    gcc \
    wget \
    curl \
    rake \
    bison \
    openssl-devel \
    make \
    unzip

sudo yum install -y epel-release
wget http://rpms.famillecollet.com/enterprise/remi-release-7.rpm
sudo rpm -Uvh remi-release-7*.rpm

sudo sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/epel*
sudo sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/remi*

sudo yum --enablerepo=epel install -y htop tig tree

# redis 4.0.11
sudo yum install --enablerepo=epel,remi redis
sudo systemctl start redis
sudo systemctl enable redis

# nginx 1.15.3, ngx_mruby 2.1.2
git clone -b v2.1.2 https://github.com/matsumotory/ngx_mruby.git
cd ngx_mruby && sh build.sh && sudo make install
# https://www.nginx.com/resources/wiki/start/topics/examples/systemd/
# nginx conf
sudo systemctl start nginx
sudo systemctl enable nginx

# mysql
sudo rpm -ivh http://dev.mysql.com/get/mysql57-community-release-el7-8.noarch.rpm
sudo sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/mysql-community*
sudo yum --enablerepo=mysql57-community,mysql57-community-source install mysql-community-server
echo 'skip_grant_table' | sudo tee -a /etc/my.cnf
sudo systemctl start mysqld.service
sudo systemctl enable mysqld.service
