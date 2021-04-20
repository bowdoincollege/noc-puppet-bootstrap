# symlink code and dist dirs to /usr/local
file { [ '/usr/local/etc/puppet', '/usr/local/etc/puppet/environments', '/usr/local/etc/puppet/dist' ]:
  ensure => directory,
  owner  => 'puppet',
  group  => 'puppet',
  mode   => '0775',
}
-> file { '/etc/puppetlabs/code/environments':
  ensure => 'link',
  target => '/usr/local/etc/puppet/environments',
  owner  => 'puppet',
  group  => 'puppet',
  force  => true  # replace existing environments from puppetserver package
}
-> file { '/etc/puppetlabs/dist':
  ensure => 'link',
  target => '/usr/local/etc/puppet/dist',
  owner  => 'puppet',
  group  => 'puppet',
}

# r10k
class { '::r10k':
  remote => $::remote,
} ->
exec { 'r10k-deploy':
  user => "puppet",
  path => "/usr/bin",
  command => "r10k deploy environment -pv"
}

# enc
file { '/etc/puppetlabs/master-enc.rb':
  owner   => 'puppet',
  group   => 'puppet',
  mode    => '0755',
  source  => '/etc/puppetlabs/code/environments/production/site/profile/files/puppet/master-enc.rb',
  require => Exec['r10k-deploy']
} ->
ini_setting { 'external_nodes':
  ensure  => present,
  path    => "/etc/puppetlabs/puppet/puppet.conf",
  section => "server",
  setting => 'external_nodes',
  value   => '/etc/puppetlabs/master-enc.rb'
} ->
ini_setting { 'node_terminus':
  ensure  => present,
  path    => "/etc/puppetlabs/puppet/puppet.conf",
  section => "server",
  setting => 'node_terminus',
  value   => 'exec'
}

# hiera
class { '::hiera':
  hiera_version   => '5',
  hiera5_defaults =>  {
     "data_hash" => "yaml_data",
     "datadir"   =>   "/etc/puppetlabs/code/environments/%{environment}/hieradata",
  },
  hierarchy => [
    {  "name"       => "host/role",
       "paths"      => [
          'hosts/%{facts.hostname}.yaml',
          'roles/%{role}.yaml',
       ],
       "lookup_key" => "eyaml_lookup_key",
       "options"    => {
         "pkcs7_private_key" => "/etc/puppetlabs/puppet/keys/private_key.pkcs7.pem",
         "pkcs7_public_key"  => "/etc/puppetlabs/puppet/keys/public_key.pkcs7.pem"
       },
    },
    {  "name"       => "module",
       "glob"       => "modules/*.yaml",
       "lookup_key" => "eyaml_lookup_key",
       "options"    => {
         "pkcs7_private_key" => "/etc/puppetlabs/puppet/keys/private_key.pkcs7.pem",
         "pkcs7_public_key"  => "/etc/puppetlabs/puppet/keys/public_key.pkcs7.pem"
       },
    },
    {  "name"       => "common",
       "path"       => "common.yaml",
       "lookup_key" => "eyaml_lookup_key",
       "options"    => {
         "pkcs7_private_key" => "/etc/puppetlabs/puppet/keys/private_key.pkcs7.pem",
         "pkcs7_public_key"  => "/etc/puppetlabs/puppet/keys/public_key.pkcs7.pem"
       },
    },

  ],
  create_symlink => false,
  require        => Exec['r10k-deploy']
}

service { 'puppetserver':
  ensure  => 'running',
  require => [ 
    Class['hiera'],
    Class['r10k'], 
    File['/etc/puppetlabs/code/environments'],
    File['/etc/puppetlabs/master-enc.rb'],
  ]
}
