Class {
	#name : 'AmqpConnectionBuilder',
	#superclass : 'Object',
	#instVars : [
		'parameters',
		'hostname',
		'username',
		'password',
		'portNumber',
		'protocolClass',
		'clientProperties'
	],
	#category : 'Ansible-Protocol-Core',
	#package : 'Ansible-Protocol-Core'
}

{ #category : 'instance creation' }
AmqpConnectionBuilder class >> forProtocol: aProtocolClass [

	^self new initializeForProtocol: aProtocolClass
]

{ #category : 'initialization' }
AmqpConnectionBuilder >> atClientProperty: aName put: aValue [ 

	clientProperties at: aName put: aValue 
]

{ #category : 'building' }
AmqpConnectionBuilder >> build [

	protocolClass ifNil: [ Error signal: 'Protocol must be configured' ].

	^ AmqpConnection
		  to: hostname
		  over: portNumber
		  using: protocolClass
		  with: self credentials
		  parameterizedBy: parameters
		  extraProperties: clientProperties
]

{ #category : 'private-accessing' }
AmqpConnectionBuilder >> credentials [

	^ AmqpPlainCredentials new
		username: username;
		password: password
]

{ #category : 'private-accessing' }
AmqpConnectionBuilder >> defaultPortNumber [

	^ protocolClass portNumber
]

{ #category : 'configuring' }
AmqpConnectionBuilder >> hostname: aHostname [
	
	hostname := aHostname 
]

{ #category : 'initialization' }
AmqpConnectionBuilder >> initialize [

	super initialize.
	self
		username: 'guest';
		password: 'guest';
		hostname: 'localhost'.
	clientProperties := Dictionary new. 
	parameters := AmqpConnectionParameters new
		              channelMax: 0;
		              frameMax: 131072;
		              heartbeat: 0
]

{ #category : 'initialization' }
AmqpConnectionBuilder >> initializeForProtocol: aProtocolClass [

	protocolClass := aProtocolClass.
	self portNumber: self defaultPortNumber
]

{ #category : 'configuring' }
AmqpConnectionBuilder >> password: aPassword [

	password := aPassword
]

{ #category : 'configuring' }
AmqpConnectionBuilder >> portNumber: aPortNumber [

	portNumber := aPortNumber
]

{ #category : 'configuring' }
AmqpConnectionBuilder >> protocol: aProtocol [

	protocolClass := aProtocol
]

{ #category : 'configuring' }
AmqpConnectionBuilder >> username: anUsername [

	username := anUsername
]
