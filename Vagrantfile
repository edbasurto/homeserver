# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
  config.ssh.insert_key = false

  '''
  config.vm.defne "vagrantvm" do |app|
    app.vm.hostname = "ookami-app.test"
    app.vm.network :private_network, ip:"192.168.57.55"
  end
  '''

  config.vm.network :private_network, ip:"192.168.57.55"

  config.vm.network 'forwarded_port', host: 3005, guest: 3005, host_ip: '127.0.0.1'

  config.vm.provision "ansible" do |ansible|
    ansible.compatibility_mode = "2.0"
    ansible.playbook = "playbook.yml"
  end
end
