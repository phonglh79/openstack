#!/usr/bin/bash

controller='192.168.100.10'
compute='192.168.100.11'
network='192.168.100.12'


echo "Create key ssh"
sleep 2
ssh-keygen -q -t rsa -f ~/.ssh/id_rsa -N ''

systemctl stop firewalld && systemctl disable firewalld
systemctl stop NetworkManager && systemctl disable NetworkManager

sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config


requirements(){
echo "\nrequirements"
sleep 2
    # Pre-Requirements
    yum -y install centos-release-openstack-queens epel-release
    curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | sudo bash
    yum -y install MariaDB-server
    systemctl enable mariadb
    systemctl start mariadb
mysql_secure_installation <<EOF

y
123456
123456
y
y
y
y
EOF
printf "\ninstall rabbitmq memcached  "
sleep 2
    yum --enablerepo=epel -y install rabbitmq-server memcached
    systemctl start rabbitmq-server memcached
    systemctl enable rabbitmq-server memcached
    rabbitmqctl add_user openstack password
    rabbitmqctl set_permissions openstack ".*" ".*" ".*"
}
keytone (){

echo "\nkeytone"
sleep 2
################ Configure Keystone#1

mysql -uroot -p123456 -e "create database keystone;"
mysql -uroot -p123456 -e "grant all privileges on keystone.* to keystone@'localhost' identified by 'password';"
mysql -uroot -p123456 -e "grant all privileges on keystone.* to keystone@'%' identified by 'password';"
mysql -uroot -p123456 -e "flush privileges;"

yum --enablerepo=centos-openstack-queens,epel -y install openstack-keystone openstack-utils python-openstackclient httpd mod_wsgi

#vi /etc/keystone/keystone.conf
token_conf='/etc/keystone/keystone.conf'
sed -i "s/\#memcache_servers = localhost:11211/memcache_servers = $controller:11211/g" $token_conf
sed -i "s/\#connection = <None>/connection = mysql+pymysql:\/\/keystone:password@$controller\/keystone/g" $token_conf
sed -i "s/\#provider = fernet/provider = fernet/g"  $token_conf
su -s /bin/bash keystone -c "keystone-manage db_sync"
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone


keystone-manage bootstrap --bootstrap-password adminpassword \
--bootstrap-admin-url http://$controller:5000/v3/ \
--bootstrap-internal-url http://$controller:5000/v3/ \
--bootstrap-public-url http://$controller:5000/v3/ \
--bootstrap-region-id RegionOne

ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
systemctl enable httpd
systemctl start httpd


#Configure Keystone#2

cat > "keystonerc" <<END
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=adminpassword
export OS_AUTH_URL=http://$controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export PS1='[\u@\h \W(keystone)]\$ '
END

chmod 600 ~/keystonerc

source ~/keystonerc

openstack project create --domain default --description "Service Project" service
openstack project list
}

glance (){

echo "\nglance"
sleep 2
#Configure Glance

source keystonerc && openstack user create --domain default --project service --password servicepassword glance
source keystonerc && openstack role add --project service --user glance admin
source keystonerc && openstack service create --name glance --description "OpenStack Image service" image

openstack endpoint create --region RegionOne image public http://$controller:9292
openstack endpoint create --region RegionOne image internal http://$controller:9292
openstack endpoint create --region RegionOne image admin http://$controller:9292

mysql -uroot -p123456 -e "create database glance;"
mysql -uroot -p123456 -e "grant all privileges on glance.* to glance@'localhost' identified by 'password';"
mysql -uroot -p123456 -e "grant all privileges on glance.* to glance@'%' identified by 'password';"
mysql -uroot -p123456 -e "flush privileges;"

printf "\nInstall glance"
sleep 2
yum --enablerepo=centos-openstack-queens,epel -y install openstack-glance


#vi /etc/glance/glance-api.conf
cat > "/etc/glance/glance-api.conf" <<END
# create new
[DEFAULT]
bind_host = 0.0.0.0

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
debug = true


[database]
# MariaDB connection info
connection = mysql+pymysql://glance:password@$controller/glance

# keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$controller:5000
auth_url = http://$controller:5000
memcached_servers = $controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = servicepassword

[paste_deploy]
flavor = keystone


END

#vi /etc/glance/glance-registry.conf

cat > "/etc/glance/glance-registry.conf" <<END
# create new
[DEFAULT]
bind_host = 0.0.0.0

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
debug = true

[database]
# MariaDB connection info
connection = mysql+pymysql://glance:password@$controller/glance

# keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$controller:5000
auth_url = http://$controller:5000
memcached_servers = $controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = servicepassword

[paste_deploy]
flavor = keystone

END

chmod 640 /etc/glance/glance-api.conf /etc/glance/glance-registry.conf
chown root:glance /etc/glance/glance-api.conf /etc/glance/glance-registry.conf
su -s /bin/bash glance -c "glance-manage db_sync"
systemctl start openstack-glance-api openstack-glance-registry
systemctl enable openstack-glance-api openstack-glance-registry

}
nova_Keystone (){
echo "\nnova_Keystone"
sleep 2
echo "\nAdd nova user project"
####Configure Nova#1
source keystonerc && openstack user create --domain default --project service --password servicepassword nova
source keystonerc && openstack role add --project service --user nova admin
source keystonerc && openstack user create --domain default --project service --password servicepassword placement
source keystonerc && openstack role add --project service --user placement admin
source keystonerc && openstack service create --name nova --description "OpenStack Compute service" compute
source keystonerc && openstack service create --name placement --description "OpenStack Compute Placement service" placement

source keystonerc && openstack endpoint create --region RegionOne compute public http://$controller:8774/v2.1/%\(tenant_id\)s
source keystonerc && openstack endpoint create --region RegionOne compute internal http://$controller:8774/v2.1/%\(tenant_id\)s
source keystonerc && openstack endpoint create --region RegionOne compute admin http://$controller:8774/v2.1/%\(tenant_id\)s
source keystonerc && openstack endpoint create --region RegionOne placement public http://$controller:8778
source keystonerc && openstack endpoint create --region RegionOne placement internal http://$controller:8778
source keystonerc && openstack endpoint create --region RegionOne placement admin http://$controller:8778


mysql -u root -p123456 -e "create database nova;"
mysql -u root -p123456 -e "grant all privileges on nova.* to nova@'localhost' identified by 'password';"
mysql -u root -p123456 -e "grant all privileges on nova.* to nova@'%' identified by 'password';"
mysql -u root -p123456 -e "create database nova_api;"
mysql -u root -p123456 -e "grant all privileges on nova_api.* to nova@'localhost' identified by 'password';"
mysql -u root -p123456 -e "grant all privileges on nova_api.* to nova@'%' identified by 'password';"
mysql -u root -p123456 -e "create database nova_placement;"
mysql -u root -p123456 -e "grant all privileges on nova_placement.* to nova@'localhost' identified by 'password';"
mysql -u root -p123456 -e "grant all privileges on nova_placement.* to nova@'%' identified by 'password';"
mysql -u root -p123456 -e "create database nova_cell0;"
mysql -u root -p123456 -e "grant all privileges on nova_cell0.* to nova@'localhost' identified by 'password';"
mysql -u root -p123456 -e "grant all privileges on nova_cell0.* to nova@'%' identified by 'password';"
mysql -u root -p123456 -e "flush privileges;"

}

nova_install_conf(){
echo "nova_install_conf"
sleep 2
echo "\nInstall Nova services"
#########Configure Nova#2
yum --enablerepo=centos-openstack-queens,epel -y install openstack-nova

#vi /etc/nova/nova.conf
cat > "/etc/nova/nova.conf" << END
# create new
[DEFAULT]
# define own IP
my_ip = $controller
state_path = /var/lib/nova
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
# RabbitMQ connection info
transport_url = rabbit://openstack:password@$controller
debug = true

#neutron


[api]
auth_strategy = keystone

# Glance connection info
[glance]
api_servers = http://$controller:9292

[oslo_concurrency]
lock_path = \$state_path/tmp

# MariaDB connection info
[api_database]
connection = mysql+pymysql://nova:password@$controller/nova_api

[database]
connection = mysql+pymysql://nova:password@$controller/nova

# Keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$controller:5000
auth_url = http://$controller:5000
memcached_servers = $controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = servicepassword

[placement]
auth_url = http://$controller:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[placement_database]
connection = mysql+pymysql://nova:password@$controller/nova_placement

[wsgi]
api_paste_config = /etc/nova/api-paste.ini

# LIBVIRT
[libvirt]
virt_type=qemu


END

chgrp nova /etc/nova/nova.conf
chmod 640 /etc/nova/nova.conf

cp -f /root/openstack/controller/00-nova-placement-api.conf /etc/httpd/conf.d/

su -s /bin/bash nova -c "nova-manage api_db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 map_cell0"
su -s /bin/bash nova -c "nova-manage db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 create_cell --name cell1"

systemctl restart httpd
chown nova. /var/log/nova/nova-placement-api.log

for service in api consoleauth conductor scheduler novncproxy; do
systemctl start openstack-nova-$service
systemctl enable openstack-nova-$service
done

openstack compute service list

}
############################################# nova ALL IN ONE################################################
nova_compute(){

echo "\nnova_compute"
sleep 2

printf "\nInstall libvirt and nova-compute"
yum -y install qemu-kvm libvirt virt-install
systemctl start libvirtd
systemctl enable libvirtd

yum --enablerepo=centos-openstack-queens,epel -y install openstack-nova-compute

cat >> /etc/nova/nova.conf << END


[vnc]
enabled = True
server_listen = 0.0.0.0
server_proxyclient_address = $controller
novncproxy_base_url = http://$controller:6080/vnc_auto.html


END

systemctl start openstack-nova-compute
systemctl enable openstack-nova-compute

su -s /bin/bash nova -c "nova-manage cell_v2 discover_hosts"
openstack compute service list
}

neutron_Keystone(){
echo "\nneutron_Keystone"
sleep 2
##############Configure Neutron#1
source keystonerc && openstack user create --domain default --project service --password servicepassword neutron
source keystonerc && openstack role add --project service --user neutron admin
source keystonerc && openstack service create --name neutron --description "OpenStack Networking service" network
source keystonerc && openstack endpoint create --region RegionOne network public http://$controller:9696
source keystonerc && openstack endpoint create --region RegionOne network internal http://$controller:9696
source keystonerc && openstack endpoint create --region RegionOne network admin http://$controller:9696

mysql -u root -p123456 -e "create database neutron_ml2;"
mysql -u root -p123456 -e "grant all privileges on neutron_ml2.* to neutron@'localhost' identified by 'password';"
mysql -u root -p123456 -e "grant all privileges on neutron_ml2.* to neutron@'%' identified by 'password';"
mysql -u root -p123456 -e "flush privileges;"

}
############################################## neutron ALL IN ONE ######################################
neutron_server(){
printf "Install neutron server\n"
sleep 2
yum --enablerepo=centos-openstack-queens,epel -y install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch

#vi /etc/neutron/neutron.conf
cat > "/etc/neutron/neutron.conf" << END
# create new
[DEFAULT]
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
state_path = /var/lib/neutron
dhcp_agent_notification = True
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
# RabbitMQ connection info
transport_url = rabbit://openstack:password@$controller
debug = true

# Keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$controller:5000
auth_url = http://$controller:5000
memcached_servers = $controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = servicepassword

# MariaDB connection info
[database]
connection = mysql+pymysql://neutron:password@$controller/neutron_ml2

# Nova connection info
[nova]
auth_url = http://$controller:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = servicepassword

[oslo_concurrency]
lock_path = \$state_path/tmp

END

chmod 640 /etc/neutron/neutron.conf
chgrp neutron /etc/neutron/neutron.conf

l3_ini='/etc/neutron/l3_agent.ini'
sed -i "s/\#interface_driver = <None>/interface_driver = openvswitch/g" $l3_ini

dhcp_ini='/etc/neutron/dhcp_agent.ini'
sed -i "s/\#interface_driver = <None>/interface_driver = openvswitch/g" $dhcp_ini
sed -i "s/\#dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq/dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq\n\nenable_isolated_metadata = true/g" $dhcp_ini

metadata_ini='/etc/neutron/metadata_agent.ini'
sed -i "s/\#nova_metadata_host = 127.0.0.1/nova_metadata_host = $controller/g" $metadata_ini
sed -i "s/\#metadata_proxy_shared_secret =/metadata_proxy_shared_secret = metadata_secret/g" $metadata_ini
sed -i "s/\#memcache_servers = localhost:11211/memcache_servers = $controller:11211/g" $metadata_ini

ml2_ini='/etc/neutron/plugins/ml2/ml2_conf.ini'
sed -i "s/\#type_drivers = local,flat,vlan,gre,vxlan,geneve/type_drivers = flat,vlan,gre,vxlan/g" $ml2_ini
sed -i "s/\#tenant_network_types = local/tenant_network_types = vxlan/g" $ml2_ini
sed -i "s/\#mechanism_drivers =/mechanism_drivers = openvswitch,l2population/g" $ml2_ini
sed -i "s/\#extension_drivers =/extension_drivers = port_security/g" $ml2_ini


openvswitch_ini='/etc/neutron/plugins/ml2/openvswitch_agent.ini'
sed -i "s/\#firewall_driver = <None>/firewall_driver = openvswitch/g" $openvswitch_ini
sed -i "s/\#enable_security_group = true/enable_security_group = true/g" $openvswitch_ini
sed -i "s/\#enable_ipset = true/enable_ipset = true/g" $openvswitch_ini

con_nova_conf='/etc/nova/nova.conf'
sed -i "s/\#neutron/use_neutron = True\nlinuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver\nfirewall_driver = nova.virt.firewall.NoopFirewallDriver\nvif_plugging_is_fatal = True\nvif_plugging_timeout = 300/g" $con_nova_conf

cat >> "/etc/nova/nova.conf" << END
[neutron]
auth_url = http://$controller:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = servicepassword
service_metadata_proxy = True
metadata_proxy_shared_secret = metadata_secret


END

systemctl start openvswitch
systemctl enable openvswitch
ovs-vsctl add-br br-int

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/bash neutron -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugin.ini upgrade head"

for service in server dhcp-agent l3-agent metadata-agent openvswitch-agent; do
systemctl start neutron-$service
systemctl enable neutron-$service
done

systemctl restart openstack-nova-api openstack-nova-compute
source keystonerc && openstack network agent list

}

###########Configure Horizon

horizon_install(){

printf "horizon_install\n"
sleep 2

yum --enablerepo=centos-openstack-queens,epel -y install openstack-dashboard

#vi /etc/openstack-dashboard/local_settings
cp -f /root/openstack/controller/local_settings /etc/openstack-dashboard/
local_settings='/etc/openstack-dashboard/local_settings'
sed -i "s/ALLOWED_HOSTS = \['horizon.example.com', 'localhost']/ALLOWED_HOSTS = ['$controller', 'localhost']/g" $local_settings
sed -i "s/\'LOCATION': '$controller:11211',/\   	'LOCATION': '$controller:11211',/g" $local_settings
sed -i "s/OPENSTACK_HOST = \"127.0.0.1\"/OPENSTACK_HOST = \"$controller\"/g" $local_settings

dashboard_conf='/etc/httpd/conf.d/openstack-dashboard.conf'
sed -i "s/WSGISocketPrefix run\/wsgi/WSGISocketPrefix run\/wsgi\nWSGIApplicationGroup %{GLOBAL}/g" $dashboard_conf

printf "Restart httpd\n"
systemctl restart httpd


}

 ######## BO QUA Configure Neutron#3 (Control Node) NEU control, network cung host
 ######## BO QUA   Configure Neutron#4 (Network Node)  NEU control, network cung host
  ######## BO QUA Configure Neutron#5 (Compute Node) NEU control, network,compute cung host

###########################################  Neutron Network (VXLAN)

vxlan_all(){
    prinf "config vxlan\n"
    all_ml2_ini='/etc/neutron/plugins/ml2/ml2_conf.ini'
    sed -i "s/\#type_drivers = local,flat,vlan,gre,vxlan,geneve/type_drivers = flat,vlan,gre,vxlan/g" $all_ml2_ini
    sed -i "s/\#tenant_network_types = local/tenant_network_types = vxlan/g" $all_ml2_ini
    sed -i "s/\#flat_networks = \*/flat_networks = physnet1/g" $all_ml2_ini
    sed -i "s/\[ml2_type_vxlan]/\[ml2_type_vxlan]\n\#ranges =/g" $all_ml2_ini
    sed -i "s/\#ranges =/\nvni_ranges = 1:1000/" $all_ml2_ini

    ovs-vsctl add-br br-ens37
    ovs-vsctl add-port br-ens37 ens37

    all_openvswitch_ini='/etc/neutron/plugins/ml2/openvswitch_agent.ini'
    sed -i "s/\[agent]/\[agent]\ntunnel_types = vxlan\nl2_population = True\nprevent_arp_spoofing = True/g" $all_openvswitch_ini
    sed -i "s/\#local_ip = <None>/local_ip = $controller/g" $all_openvswitch_ini
    sed -i "s/\#bridge_mappings =/bridge_mappings = physnet1:br-ens37/g" $all_openvswitch_ini

    systemctl restart neutron-server
    for service in dhcp-agent l3-agent metadata-agent openvswitch-agent; do
    systemctl restart neutron-$service
    done
    systemctl restart neutron-openvswitch-agent

    printf "config VXLAN done"

}

vxlan_con(){
    prinf "config vxlan controller\n"
    con_ml2_ini='/etc/neutron/plugins/ml2/ml2_conf.ini'
    sed -i "s/\#type_drivers = local,flat,vlan,gre,vxlan,geneve/type_drivers = flat,vlan,gre,vxlan/g" con_ml2_ini
    sed -i "s/\#flat_networks = \*/flat_networks = physnet1/g" con_ml2_ini
    sed -i "s/\#tenant_network_types = local/tenant_network_types = vxlan/g" con_ml2_ini
    sed -i "s/\[ml2_type_vxlan]/\[ml2_type_vxlan]\n\#ranges =/g" con_ml2_ini
    sed -i "s/\#ranges =/\nvni_ranges = 1:1000/" con_ml2_ini

    systemctl restart neutron-server

     printf "config VXLAN on controller done"

}


vxlan_net(){
    prinf "config vxlan network\n"
    ovs-vsctl add-br br-ens37
    ovs-vsctl add-port br-ens37 ens37

    net_ml2_ini='/etc/neutron/plugins/ml2/ml2_conf.ini'
    sed -i "s/\#type_drivers = local,flat,vlan,gre,vxlan,geneve/type_drivers = flat,vlan,gre,vxlan/g" net_ml2_ini
    sed -i "s/\#flat_networks = \*/flat_networks = physnet1/g" net_ml2_ini
    sed -i "s/\#tenant_network_types = local/tenant_network_types = vxlan/g" net_ml2_ini
    sed -i "s/\[ml2_type_vxlan]/\[ml2_type_vxlan]\n\#ranges =/g" net_ml2_ini
    sed -i "s/\#ranges =/\nvni_ranges = 1:1000/" net_ml2_ini

    net_openvswitch_ini='/etc/neutron/plugins/ml2/openvswitch_agent.ini'
    sed -i "s/\[agent]/\[agent]\ntunnel_types = vxlan\nl2_population = True\nprevent_arp_spoofing = True/g" $net_openvswitch_ini
    sed -i "s/\#local_ip = <None>/local_ip = $network/g" $net_openvswitch_ini
    sed -i "s/\#bridge_mappings =/bridge_mappings = physnet1:br-ens37/g" $net_openvswitch_ini

    systemctl restart neutron-openvswitch-agent

    printf "config VXLAN on Network done"
}


vxlan_com(){

    prinf "config vxlan compute\n"
    com_ml2_ini='/etc/neutron/plugins/ml2/ml2_conf.ini'
    sed -i "s/\#type_drivers = local,flat,vlan,gre,vxlan,geneve/type_drivers = flat,vlan,gre,vxlan/g" $com_ml2_ini
    sed -i "s/\#tenant_network_types = local/tenant_network_types = vxlan/g" $com_ml2_ini
    sed -i "s/\#flat_networks = \*/flat_networks = physnet1/g" $com_ml2_ini
    sed -i "s/\[ml2_type_vxlan]/\[ml2_type_vxlan]\n\#ranges =/g" $com_ml2_ini
    sed -i "s/\#ranges =/\nvni_ranges = 1:1000/" $com_ml2_ini

    com_openvswitch_ini='/etc/neutron/plugins/ml2/openvswitch_agent.ini'
    sed -i "s/\[agent]/\[agent]\ntunnel_types = vxlan\nl2_population = True\nprevent_arp_spoofing = True/g" $com_openvswitch_ini
    sed -i "s/\#local_ip = <None>/local_ip = $compute/g"
    systemctl restart neutron-server

    printf "config VXLAN on Computer done"


}

key_private(){

printf "key_private\n"
sleep 2

source /root/keystonerc && openstack keypair create --public-key /root/.ssh/id_rsa.pub mykey

}

options=("Install ALL IN ONE" "2 NODE CONTROLLER-COMPUTE" "3 NODE CONTROLLER-NETWORK-COMPUTE" "3 NODE CONTROLLER-COMPUTE-STORAGE" ) # End Options

printf "=========================================================================\n"
printf "                          Menu\n"
printf "=========================================================================\n"
PS3="
$prompt"
select opt in "${options[@]}" "THOAT"; do

    case "$REPLY" in
	    1 ) requirements
	        keytone
	        glance
	        nova_Keystone
	        nova_install_conf
	        nova_compute
	        neutron_Keystone
	        neutron_server
	        horizon_install
	        vxlan_all
	        key_private
	        reboot;;
	    2 ) exit;;
	    3 ) exit;;
		    # End Menu

	    $(( ${#options[@]}+1 )) ) printf "\nChao tam biet!\nHen gap lai ban o https://emobi.vn/\n\n"; break;;
	    *) echo "Ban nhap sai, vui long nhap theo so thu tu tren danh sach";continue;;

    esac

done



















































