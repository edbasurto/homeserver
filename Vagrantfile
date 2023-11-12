# -*- mode: ruby -*-
# vi: set ft=ruby :


Vagrant.configure("2") do |config|

  config.vm.box = "generic/ubuntu2204"
  config.ssh.insert_key = false

  config.vm.network :private_network, ip:"192.168.56.44"

  config.vm.provision "ansible" do |ansible|
    #ansible.compatibility_mode = "2.0"
    ansible.playbook = "playbook.yml"
  end
end
