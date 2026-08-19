const express = require('express');
const bodyParser = require('bodyParser');
const mongodb = require('mongodb');

const{huplanModel} =reqire('../stock_data/models/huplanModel');
const app = express();
const PORT =3000;
app.use(bodyParser.json());
